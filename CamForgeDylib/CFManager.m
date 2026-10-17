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
@property (nonatomic, strong, nullable) dispatch_source_t renderTimer; ///< 渲染节拍器
- (void)applySourceType:(CFSourceType)type urlOrPath:(nullable NSString *)s;
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
    [CFLogger.shared log:@"停止替换（已恢复真实相机）"];
}

#pragma mark - 选项

- (void)syncRenderOptions {
    self.converter.targetPixelFormat = self.targetPixelFormat;
    self.converter.rotationDegrees = self.rotationDegrees;
    self.converter.mirrored = self.mirrored;
    self.converter.fillMode = self.fillMode;
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

        // 3) 打包 SampleBuffer，PTS 按 30fps 递增
        self.lastPTS = CMTimeAdd(self.lastPTS, CMTimeMake(1, 30));
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
        CFRelease(sb);
        self.outputSize = self.converter.outputSize;
        [CFLogger.shared incRendered];
    }
}

#pragma mark - 供 proxy 调用

- (CMSampleBufferRef)nextVideoSampleBuffer {
    if (!self.replacing) return NULL;
    return (CMSampleBufferRef)[self.jitter popRetained];   // +1 或 NULL
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
    [CFLogger.shared log:@"session startRunning，补扫 outputs: %lu", (unsigned long)session.outputs.count];
    for (AVCaptureOutput *o in session.outputs) {
        if ([o isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            [CFCaptureProxy wrapVideoOutput:(AVCaptureVideoDataOutput *)o];
        } else if ([o isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            [CFCaptureProxy wrapAudioOutput:(AVCaptureAudioDataOutput *)o];
        }
    }
}

- (void)showMenu {
    [[CFMenu shared] toggle];
}

@end
