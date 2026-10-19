//
//  CFManager.m — 渲染调度中枢
//
//  渲染线程：com.camforge.render（串行队列 + dispatch_source 30fps 节拍）
//  数据流：source(BGRA) → converter(目标格式) → CMSampleBuffer → jitter → proxy 取走
//
//  2026-10-18 加固：
//   - format description 为 NULL 时不再硬塞给 CMSampleBufferCreateReadyWithImageBuffer
//   - 取帧前抓一份 strong 源引用，避免切源瞬间被换掉
//   - 逐帧异常兜底，出错只记 lastError，不让整个进程崩
//   - 新增：旋转 / 镜像 / 填充适应 / 画面去重 / 音频去重 / 期望像素格式跟随
//

#import "CFManager.h"
#import "CFPixelConverter.h"
#import "CFJitterBuffer.h"
#import "CFCaptureProxy.h"
#import "CFLogger.h"
#import "CFSyntheticSource.h"
#import "CFAssetSource.h"
#import "CFAlbumSource.h"
#import "CFExternalSource.h"
#import "CFDirectSource.h"
#import "CFMovieSource.h"
#import "CFMenu.h"
#import <math.h>
#import <string.h>
#import <QuartzCore/QuartzCore.h>

#if CF_HAVE_FFMPEG
#import <libswresample/swresample.h>
#endif

/// 内容摘要（FNV-1a，抽样扫描；用于画面去重）
static uint64_t cf_digest(CVPixelBufferRef pb) {
    if (!pb) return 0;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    uint64_t h = 1469598103934665603ULL;
    void *base = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBaseAddressOfPlane(pb, 0)
                                           : CVPixelBufferGetBaseAddress(pb);
    size_t len = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                                           : CVPixelBufferGetDataSize(pb);
    if (base && len > 0) {
        size_t step = len / 256 ? len / 256 : 1;
        const uint8_t *p = (const uint8_t *)base;
        for (size_t i = 0; i < len; i += step) {
            h ^= p[i];
            h *= 1099511628211ULL;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return h;
}

/// 原音频是否静音（抽样判定；用于"音频去重"：静音段不注入，避免连成一片嗡声）
static BOOL cf_block_is_silent(CMBlockBufferRef block, size_t totalBytes) {
    if (!block || totalBytes == 0) return YES;
    char *data = NULL;
    size_t lenAt = 0, total = 0;
    if (CMBlockBufferGetDataPointer(block, 0, &lenAt, &total, &data) != noErr || !data) return NO;
    size_t n = total < totalBytes ? total : totalBytes;
    size_t step = n / 128 ? n / 128 : 1;
    for (size_t i = 0; i + 1 < n; i += step * 2) {
        int16_t v = 0;
        memcpy(&v, data + i, 2);
        if (v > 64 || v < -64) return NO;
    }
    return YES;
}

@interface CFManager ()
@property (nonatomic, assign) CMTime lastPTS;                        ///< 递增 PTS（30fps）
@property (nonatomic, assign) uint64_t lastVideoDigest;              ///< 画面去重摘要
@property (nonatomic, assign, nullable) CMSampleBufferRef lastSampleBuffer; ///< 最近一帧（回调比渲染快时复用）
@property (nonatomic, assign, nullable) CVPixelBufferRef lastPixelBuffer;      ///< 最近一个像素缓冲（供原帧重建）
@property (nonatomic, assign) CGSize cameraSize;                                ///< 相机实际输出尺寸（0 表示未知）
@property (nonatomic, strong, nullable) dispatch_source_t renderTimer; ///< 渲染节拍器
- (void)applySourceType:(CFSourceType)type urlOrPath:(nullable NSString *)s;
- (NSUInteger)scanSessionOutputs:(AVCaptureSession *)session;
- (void)retryScanSession:(AVCaptureSession *)session attempt:(NSInteger)attempt;
- (void)resetLastSampleBuffer;
- (CVPixelBufferRef)dequeuePixelBuffer;
- (void)noteCameraSize:(CGSize)size;
@end

@implementation CFManager

+ (instancetype)shared {
    static CFManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [CFManager new]; });
    return m;
}

- (instancetype)init {
    if (self = [super init]) {
        _outputSize = CGSizeMake(1280, 720);
        _converter  = [CFPixelConverter new];
        _jitter     = [CFJitterBuffer new];
        _replacing  = NO;
        _audioReplaceEnabled = NO;
        _source     = [CFSyntheticSource new];   // 默认合成图案，零外部依赖
        _sourceType = CFSourceTypeSynthetic;
        _lastPTS    = kCMTimeZero;
        _targetPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        _rotationDegrees = 0;
        _mirrored = NO;
        _fillMode = YES;
        _frameDedupe = NO;
        _audioDedupe = NO;
        _panelAlpha = 1.0;
    }
    return self;
}

#pragma mark - 生命周期

- (void)startReplacing {
    if (self.replacing) return;
    if (self.sourceType == CFSourceTypePassthrough) {
        self.lastError = @"当前是相机透传模式，切到「视频」「网络」或「直连」再开始";
        [CFLogger.shared log:@"startReplacing 被拒绝：透传模式"];
        return;
    }
    self.replacing = YES;
    self.lastError = nil;
    self.lastPTS = kCMTimeZero;
    [self syncRenderOptions];
    if ([self.source respondsToSelector:@selector(prepare)]) {
        [self.source prepare];
    }

    if (_renderTimer) {
        dispatch_source_cancel(_renderTimer);
        _renderTimer = nil;
    }
    static dispatch_queue_t q;
    static dispatch_once_t onceQ;
    dispatch_once(&onceQ, ^{
        q = dispatch_queue_create("com.camforge.render", DISPATCH_QUEUE_SERIAL);
    });
    _renderTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    // 30fps 渲染节拍；lead=1ms 防累积漂移
    dispatch_source_set_timer(_renderTimer, DISPATCH_TIME_NOW,
                              (uint64_t)(1.0 / 30.0 * NSEC_PER_SEC), 1 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_renderTimer, ^{
        @autoreleasepool {
            [weakSelf renderOneFrame];
        }
    });
    dispatch_resume(_renderTimer);
    [CFLogger.shared log:@"开始替换（源: %@，旋转 %ld，镜像 %d，填充 %d）",
        self.source.sourceName, (long)self.rotationDegrees, self.mirrored, self.fillMode];
}

- (void)stopReplacing {
    if (!self.replacing) return;
    self.replacing = NO;
    if (_renderTimer) {
        dispatch_source_cancel(_renderTimer);
        _renderTimer = nil;
    }
    if ([self.source respondsToSelector:@selector(teardown)]) {
        [self.source teardown];
    }
    [self.jitter drain];
    [self resetLastSampleBuffer];
    self.cameraSize = CGSizeZero;
    self.converter.targetSize = CGSizeZero;
    [CFLogger.shared log:@"停止替换（已恢复真实相机）"];
}

#pragma mark - 选项

- (void)syncRenderOptions {
    self.converter.targetPixelFormat = self.targetPixelFormat;
    self.converter.rotationDegrees = self.rotationDegrees;
    self.converter.mirrored = self.mirrored;
    self.converter.fillMode = self.fillMode;
}

/// 从真实回调帧里读像素格式：比 videoSettings 可靠（videoSettings 可能为 nil 或滞后）
- (void)noteIncomingPixelFormat:(OSType)fmt {
    if (fmt == 0) return;
    if (fmt == self.targetPixelFormat) return;
    if (fmt != kCVPixelFormatType_32BGRA &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        [CFLogger.shared log:@"回调帧像素格式 0x%x 不支持，保持 0x%x", fmt, self.targetPixelFormat];
        return;
    }
    self.targetPixelFormat = fmt;
    [self syncRenderOptions];
    [CFLogger.shared log:@"按实际回调帧修正像素格式 -> 0x%x", fmt];
}

- (void)noteVideoOutputSettings:(NSDictionary *)settings {
    if (![settings isKindOfClass:[NSDictionary class]]) return;
    id v = settings[(id)kCVPixelBufferPixelFormatTypeKey];
    OSType fmt = 0;
    if ([v isKindOfClass:[NSNumber class]]) fmt = (OSType)[v unsignedIntValue];
    if (fmt == 0) {
        // videoSettings 为空时 AVFoundation 默认给 420v
        fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    // 只支持这三种；其他格式一律退回 420v（CoreImage 能渲染的就这些）
    if (fmt != kCVPixelFormatType_32BGRA &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        [CFLogger.shared log:@"videoSettings 格式 0x%x 不支持，回退 420v", fmt];
        fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    if (self.targetPixelFormat != fmt) {
        self.targetPixelFormat = fmt;
        [self syncRenderOptions];
        [CFLogger.shared log:@"跟随目标 output 像素格式: 0x%x", fmt];
    }
}

#pragma mark - 源切换

- (void)switchToSourceType:(CFSourceType)type urlOrPath:(NSString *)s {
    // 已经在主线程就同步执行：否则「切源 → 立刻开始替换」会先拿旧源出几帧
    if ([NSThread isMainThread]) {
        [self applySourceType:type urlOrPath:s];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applySourceType:type urlOrPath:s];
        });
    }
}

- (void)applySourceType:(CFSourceType)type urlOrPath:(NSString *)s {
    [self syncRenderOptions];
    if ([self.source respondsToSelector:@selector(teardown)]) {
        [self.source teardown];
    }

    switch (type) {
        case CFSourceTypeVideoFile:
            if (s.length == 0) {
                // 视频模式留空 = 用相册最新一条
                self.source = [CFAlbumSource new];
                self.sourceType = CFSourceTypeAlbum;
            } else {
                self.source = [[CFAssetSource alloc] initWithURL:[NSURL fileURLWithPath:s]];
                self.sourceType = CFSourceTypeVideoFile;
            }
            break;

        case CFSourceTypeAlbum:
            self.source = [CFAlbumSource new];
            self.sourceType = CFSourceTypeAlbum;
            break;

        case CFSourceTypeNetwork: {
            NSString *lower = s.lowercaseString ?: @"";
            BOOL needFFmpeg = [lower hasPrefix:@"rtsp://"] ||
                              [lower hasPrefix:@"rtmp://"] ||
                              [lower containsString:@".flv"];
            if (needFFmpeg) {
                if ([CFMovieSource available]) {
                    self.source = [[CFMovieSource alloc] initWithURLString:s isFile:NO];
                    self.sourceType = CFSourceTypeNetwork;
                } else {
                    self.lastError = @"RTSP/RTMP/FLV 需要 FFmpeg，当前构建未包含";
                    self.source = [CFSyntheticSource new];
                    self.sourceType = CFSourceTypeSynthetic;
                }
            } else {
                // http(s) / HLS / mp4 交给 AVFoundation，比 FFmpeg 更省资源
                self.source = [[CFAssetSource alloc] initWithURL:[NSURL URLWithString:s]];
                self.sourceType = CFSourceTypeNetwork;
            }
            break;
        }

        case CFSourceTypeUSB:
            // 直连 = PC 经 usbmuxd 推 JPEG 帧进来（与原版同一套传输通道）
            self.source = [[CFDirectSource alloc] initWithPort:9527];
            self.sourceType = CFSourceTypeUSB;
            break;

        case CFSourceTypePassthrough:
            [self stopReplacing];
            self.source = [CFSyntheticSource new];
            self.sourceType = CFSourceTypePassthrough;
            break;

        default:
            self.source = [CFSyntheticSource new];
            self.sourceType = CFSourceTypeSynthetic;
            break;
    }

    if (self.replacing && [self.source respondsToSelector:@selector(prepare)]) {
        [self.source prepare];
    }
    [self.menu refresh];
    [CFLogger.shared log:@"切换源: %@ (%ld)", self.source.sourceName, (long)self.sourceType];
}

- (CFMenu *)menu {
    return [CFMenu shared];
}

#pragma mark - 渲染管线

- (void)renderOneFrame {
    @autoreleasepool {
        if (!self.replacing) return;

        // 1) 源出帧（BGRA，+1）。先抓一份 strong 引用，防切源瞬间被释放
        id<CFFrameSource> src = self.source;
        CVPixelBufferRef bgra = [src nextPixelBuffer];
        if (!bgra) return;

        // 画面去重：内容没变就不重复注入
        if (self.frameDedupe) {
            uint64_t d = cf_digest(bgra);
            if (d == self.lastVideoDigest) {
                CVPixelBufferRelease(bgra);
                return;
            }
            self.lastVideoDigest = d;
        }

        // 2) 转目标像素格式（+1）
        CVPixelBufferRef out = [self.converter convertBGRA:bgra];
        CVPixelBufferRelease(bgra);
        if (!out) {
            self.lastError = @"像素转换失败（尺寸或格式不支持）";
            return;
        }

        CMVideoFormatDescriptionRef fd = [self.converter formatDescription];
        if (!fd) {
            self.lastError = @"format description 创建失败";
            CVPixelBufferRelease(out);
            return;
        }

        // 3) 打包 SampleBuffer。PTS 用墙钟（CACurrentMediaTime），不用帧计数累加：
        //    按帧计数一旦渲染被拖慢，PTS 就会落后于真实时间，下游按时间轴取帧会丢帧。
        //    同时保证严格单调（至少 +1/120s），避免重复时间戳被丢弃。
        CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
        if (CMTimeCompare(now, self.lastPTS) <= 0) {
            now = CMTimeAdd(self.lastPTS, CMTimeMake(1, 120));
        }
        self.lastPTS = now;
        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = self.lastPTS,
            .decodeTimeStamp = self.lastPTS,
        };
        CMSampleBufferRef sb = NULL;
        OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(
            kCFAllocatorDefault, out, fd, &timing, &sb);
        CVPixelBufferRelease(out);
        if (st != noErr || !sb) {
            self.lastError = [NSString stringWithFormat:@"CMSampleBuffer 创建失败 (%d)", (int)st];
            return;
        }
        [self.jitter pushSampleBuffer:sb];
        [self resetLastSampleBuffer];
        self.lastSampleBuffer = (CMSampleBufferRef)CFRetain(sb);
        self.lastPixelBuffer = (CVPixelBufferRef)CFRetain(out);
        CFRelease(sb);
        self.outputSize = self.converter.outputSize;
        [CFLogger.shared incRendered];
    }
}

#pragma mark - 供 proxy 调用

/// 取一帧待注入的图像（+1）：优先新帧，缓冲空了复用上一帧
- (CVPixelBufferRef)dequeuePixelBuffer {
    CMSampleBufferRef sb = (CMSampleBufferRef)[self.jitter popRetained];
    CVPixelBufferRef pb = NULL;
    if (sb) {
        pb = CMSampleBufferGetImageBuffer(sb);          // +0
        if (pb) CVPixelBufferRetain(pb);
        CFRelease(sb);
    }
    if (!pb && self.lastPixelBuffer) {
        pb = (CVPixelBufferRef)CFRetain(self.lastPixelBuffer);
    }
    return pb;                                          // +1 或 NULL
}

/// 注入帧构造：**用原帧的格式描述和原帧时间戳**（对应原版
/// copySampleBufferReplacingImage:withBuffer: 的语义）——下游看到的帧
/// 格式/尺寸/时间轴都没变，只是像素换了，被拒的概率最低。
/// 构造失败才回退到"自有格式描述 + 墙钟时间戳"。
- (nullable CMSampleBufferRef)nextVideoSampleBufferMatching:(CMSampleBufferRef)original {
    if (!self.replacing) return NULL;

    CVPixelBufferRef pb = [self dequeuePixelBuffer];
    if (!pb) return NULL;

    if (original) {
        [self noteCameraSize:CGSizeMake(CVPixelBufferGetWidth(CMSampleBufferGetImageBuffer(original) ?: NULL),
                                        CVPixelBufferGetHeight(CMSampleBufferGetImageBuffer(original) ?: NULL))];
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(original);
        // 取 timing 的方式照原版来：先 memset 清零，再按实际条数取第一条；
        // 取不到就保持全零（原版实测行为），不要因为取不到 timing 就换格式描述。
        CMSampleTimingInfo timing;
        memset(&timing, 0, sizeof(timing));
        CMItemCount timingCount = 0;
        CMSampleBufferGetSampleTimingInfoArray(original, 0, NULL, &timingCount);
        if (timingCount > 0) {
            CMSampleBufferGetSampleTimingInfoArray(original, 1, &timing, &timingCount);
        }
        if (fd) {
            CMSampleBufferRef out = NULL;
            OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(
                kCFAllocatorDefault, pb, fd, &timing, &out);
            if (st == noErr && out) {
                CVPixelBufferRelease(pb);
                return out;                             // +1
            }
            [CFLogger.shared log:@"按原帧重建失败(%d)，回退自有格式描述", (int)st];
        }
    }

    // 回退路径：自有格式描述 + 墙钟 PTS
    CMVideoFormatDescriptionRef fd = [self.converter formatDescription];
    if (!fd) { CVPixelBufferRelease(pb); return NULL; }
    CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
    if (CMTimeCompare(now, self.lastPTS) <= 0) now = CMTimeAdd(self.lastPTS, CMTimeMake(1, 120));
    self.lastPTS = now;
    CMSampleTimingInfo timing = { CMTimeMake(1, 30), now, now };
    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &timing, &sb);
    CVPixelBufferRelease(pb);
    if (st != noErr || !sb) return NULL;
    return sb;                                         // +1
}

- (CMSampleBufferRef)nextVideoSampleBuffer {
    if (!self.replacing) return NULL;

    CMSampleBufferRef sb = (CMSampleBufferRef)[self.jitter popRetained];   // +1 或 NULL
    if (sb) return sb;

    // 关键：App 的回调率可能高于我们的渲染率（抖音常见 60fps 回调 / 我们 30fps 出帧）。
    // 缓冲空了就复用最近一帧，绝不能透传真画面 —— 否则画面会在假帧与真帧之间交替闪，
    // 观感上就是"注入没生效"。（原版是靠 Retry 锁 30fps 解决的，我们两头都兜）
    if (self.lastSampleBuffer) {
        return (CMSampleBufferRef)CFRetain(self.lastSampleBuffer);          // +1
    }
    return NULL;
}

- (void)resetLastSampleBuffer {
    if (self.lastSampleBuffer) {
        CFRelease(self.lastSampleBuffer);
        self.lastSampleBuffer = NULL;
    }
    if (self.lastPixelBuffer) {
        CVPixelBufferRelease(self.lastPixelBuffer);
        self.lastPixelBuffer = NULL;
    }
}

/// 记住相机真实尺寸，让注入帧与真帧同尺寸（原版 _lastCameraSize / _originalCameraSize 的做法）
- (void)noteCameraSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    if (CGSizeEqualToSize(self.cameraSize, size)) return;
    self.cameraSize = size;
    self.converter.targetSize = size;      // 转换器按这个尺寸出帧
    [CFLogger.shared log:@"相机尺寸已跟随: %.0fx%.0f", size.width, size.height];
}

- (NSData *)convertPCM:(NSData *)pcm
              fromRate:(int)srcRate fromCh:(int)srcCh
                toRate:(int)dstRate toCh:(int)dstCh
             wantBytes:(NSUInteger)want {
    if (pcm.length == 0 || want == 0) return nil;
    if (srcRate == dstRate && srcCh == dstCh) return pcm;      // 格式一致直接透传

#if CF_HAVE_FFMPEG
    AVChannelLayout inL, outL;
    av_channel_layout_default(&inL, srcCh);
    av_channel_layout_default(&outL, dstCh);

    struct SwrContext *swr = NULL;
    if (swr_alloc_set_opts2(&swr, &outL, AV_SAMPLE_FMT_S16, dstRate,
                            &inL, AV_SAMPLE_FMT_S16, srcRate, 0, NULL) < 0 || !swr) {
        return nil;
    }
    if (swr_init(swr) < 0) { swr_free(&swr); return nil; }

    NSMutableData *out = [NSMutableData dataWithLength:want];
    const uint8_t *inp[1] = { (const uint8_t *)pcm.bytes };
    uint8_t *outp[1] = { (uint8_t *)out.mutableBytes };
    int outSamples = (int)(want / (2 * (NSUInteger)dstCh));
    int got = swr_convert(swr, outp, outSamples, inp, (int)(pcm.length / (2 * (NSUInteger)srcCh)));
    swr_free(&swr);
    if (got <= 0) return nil;
    out.length = (NSUInteger)got * 2 * (NSUInteger)dstCh;
    return out;
#else
    return nil;                                                // 无 FFmpeg 时不做重采样
#endif
}

- (CMSampleBufferRef)nextAudioSampleBufferMatching:(CMSampleBufferRef)original {
    if (!original) return NULL;
    if (!self.audioReplaceEnabled) {
        CFRetain(original);
        return original;                                    // 透传
    }

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(original);
    if (!fmt) { CFRetain(original); return original; }
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (!asbd || asbd->mSampleRate <= 0 || asbd->mChannelsPerFrame == 0) {
        CFRetain(original);
        return original;
    }

    CMItemCount numSamples = CMSampleBufferGetNumSamples(original);
    if (numSamples <= 0) { CFRetain(original); return original; }

    size_t frameBytes = asbd->mBytesPerFrame ? asbd->mBytesPerFrame
                                             : 2 * asbd->mChannelsPerFrame;
    size_t totalBytes = (size_t)numSamples * frameBytes;
    if (totalBytes == 0) { CFRetain(original); return original; }

    // 音频去重：原帧是静音段就不注入 —— 否则标记音会在一整段静音上连成嗡声，
    // 既没信息量又容易听出异常。判定走抽样，几乎零开销。
    if (self.audioDedupe) {
        CMBlockBufferRef srcBlock = CMSampleBufferGetDataBuffer(original);
        if (cf_block_is_silent(srcBlock, totalBytes)) {
            CFRetain(original);
            return original;
        }
    }

    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, totalBytes, kCFAllocatorDefault, NULL,
        0, totalBytes, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (st != noErr || !block) { CFRetain(original); return original; }

    // 440Hz 正弦标记音（研究用：听感上立刻能分辨注入是否生效）
    // 注意：CMBlockBufferGetDataPointer(theBuffer, offset, lengthAtOffsetOut, totalLengthOut, dataPointerOut)
    // offset 是值；totalLengthOut 在 dataPointerOut 之前
    char *data = NULL;
    size_t lengthAtOffset = 0, totalLengthOut = 0;
    if (CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset, &totalLengthOut, &data) == noErr && data) {
        BOOL filled = NO;

        // 1) 优先用「直连」推过来的 PCM（PC 推什么就播什么）
        if ([self.source isKindOfClass:[CFDirectSource class]]) {
            CFDirectSource *ds = (CFDirectSource *)self.source;
            if (ds.hasAudio) {
                NSUInteger srcRate = [CFDirectSource audioSampleRate];
                NSUInteger srcCh   = [CFDirectSource audioChannels];
                NSUInteger dstBytesPerFrame = (asbd->mBytesPerFrame ?: (2 * asbd->mChannelsPerFrame));
                NSUInteger dstSamples = totalBytes / (dstBytesPerFrame ?: 1);
                NSUInteger srcFrames  = (NSUInteger)((double)dstSamples * srcRate /
                                                     MAX(asbd->mSampleRate, 1.0));
                NSData *pcm = [ds takeAudioBytes:srcFrames * srcCh * 2];
                if (pcm.length) {
                    NSData *conv = [self convertPCM:pcm
                                           fromRate:(int)srcRate fromCh:(int)srcCh
                                             toRate:(int)asbd->mSampleRate
                                               toCh:(int)asbd->mChannelsPerFrame
                                          wantBytes:totalBytes];
                    if (conv.length) {
                        size_t n = MIN(conv.length, totalBytes);
                        memcpy(data, conv.bytes, n);
                        if (n < totalBytes) memset(data + n, 0, totalBytes - n);   // 尾部补静音
                        filled = YES;
                        [CFLogger.shared incDirectAudio];
                    }
                }
            }
        }

        // 2) 没有推流音频 → 440Hz 标记音（研究用：听感上一秒分辨注入是否生效）
        if (!filled) {
            static double phase = 0;
            double dphase = 2.0 * M_PI * 440.0 / asbd->mSampleRate;
            for (CMItemCount i = 0; i < numSamples; i++) {
                int16_t v = (int16_t)(sin(phase) * 0.3 * 32767.0);
                phase += dphase;
                if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
                for (UInt32 ch = 0; ch < asbd->mChannelsPerFrame; ch++) {
                    memcpy(data + ((size_t)i * asbd->mChannelsPerFrame + ch) * 2, &v, 2);
                }
            }
        }
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(original);
    CMTime dur = CMSampleBufferGetDuration(original);
    if (CMTIME_IS_INVALID(dur) || CMTIME_IS_INDEFINITE(dur)) {
        dur = CMTimeMake(1, (int64_t)asbd->mSampleRate);
    }
    CMSampleTimingInfo timing = { dur, pts, pts };

    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL,
                              fmt, numSamples, 1, &timing, 0, NULL, &sb);
    CFRelease(block);
    if (st != noErr || !sb) { CFRetain(original); return original; }
    return sb;   // +1
}

#pragma mark - 补挂 hook

- (void)rescanSessionOutputs:(AVCaptureSession *)session {
    if (!session) return;
    [CFLogger.shared incSession];
    NSUInteger n = [self scanSessionOutputs:session];
    [CFLogger.shared log:@"session startRunning，outputs=%lu", (unsigned long)n];
    // 输出有可能在 startRunning 之后才被 addOutput（部分 App 就是这么干的），
    // 原版的日志里也是"retry ... attempt %ld"，我们同样补扫几次。
    if (n == 0) [self retryScanSession:session attempt:1];
}

- (NSUInteger)scanSessionOutputs:(AVCaptureSession *)session {
    NSUInteger n = 0;
    for (AVCaptureOutput *o in session.outputs) {
        if ([o isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            [CFCaptureProxy wrapVideoOutput:(AVCaptureVideoDataOutput *)o];
            n++;
        } else if ([o isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            [CFCaptureProxy wrapAudioOutput:(AVCaptureAudioDataOutput *)o];
            n++;
        }
    }
    return n;
}

- (void)retryScanSession:(AVCaptureSession *)session attempt:(NSInteger)attempt {
    if (attempt > 3) {
        [CFLogger.shared log:@"补扫 3 次仍无输出：该 App 可能不走 AVCaptureSession"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * attempt * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUInteger n = [weakSelf scanSessionOutputs:session];
        [CFLogger.shared log:@"补扫第 %ld 次: outputs=%lu", (long)attempt, (unsigned long)n];
        if (n == 0) [weakSelf retryScanSession:session attempt:attempt + 1];
    });
}

- (void)showMenu {
    [[CFMenu shared] toggle];
}

@end
