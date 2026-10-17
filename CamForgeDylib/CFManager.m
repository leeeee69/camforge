//
//  CFManager.m — 渲染调度中枢
//

#import "CFManager.h"
#import "CFPixelConverter.h"
#import "CFJitterBuffer.h"
#import "CFCaptureProxy.h"
#import "CFLogger.h"
#import "CFSyntheticSource.h"
#import "CFAssetSource.h"
#import "CFMenu.h"
#import <math.h>

@interface CFManager ()
@property (nonatomic, assign) CMTime lastPTS;                        ///< 递增 PTS（30fps）
@property (nonatomic, strong, nullable) dispatch_source_t renderTimer; ///< 渲染节拍器
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
        _lastPTS    = kCMTimeZero;
    }
    return self;
}

#pragma mark - 生命周期

- (void)startReplacing {
    if (self.replacing) return;
    self.replacing = YES;
    if ([self.source respondsToSelector:@selector(prepare)]) {
        [self.source prepare];
    }
    dispatch_queue_t q = dispatch_queue_create("com.camforge.render", DISPATCH_QUEUE_SERIAL);
    _renderTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    // 30fps 渲染节拍；lead=1ms 防累积漂移
    dispatch_source_set_timer(_renderTimer, DISPATCH_TIME_NOW,
                              (uint64_t)(1.0 / 30.0 * NSEC_PER_SEC), 1 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_renderTimer, ^{
        [weakSelf renderOneFrame];
    });
    dispatch_resume(_renderTimer);
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
}

#pragma mark - 源切换

- (void)switchToSourceType:(CFSourceType)type urlOrPath:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.source respondsToSelector:@selector(teardown)]) {
            [self.source teardown];
        }
        switch (type) {
            case CFSourceTypeVideoFile:
                self.source = [[CFAssetSource alloc] initWithURL:[NSURL fileURLWithPath:s]];
                break;
            case CFSourceTypeNetwork:
                self.source = [[CFAssetSource alloc] initWithURL:[NSURL URLWithString:s]];
                break;
            default:
                self.source = [CFSyntheticSource new];
                break;
        }
        if (self.replacing && [self.source respondsToSelector:@selector(prepare)]) {
            [self.source prepare];
        }
        [self.menu refresh];
    });
}

- (CFMenu *)menu {
    return [CFMenu shared];
}

#pragma mark - 渲染管线

- (void)renderOneFrame {
    @autoreleasepool {
        // 1) 源出帧（BGRA，+1）
        CVPixelBufferRef bgra = [self.source nextPixelBuffer];
        if (!bgra) return;

        // 2) 转 NV12（相机链最常见格式，+1）
        CVPixelBufferRef nv12 = [self.converter convertBGRA:bgra];
        CVPixelBufferRelease(bgra);
        if (!nv12) return;

        // 3) 打包 SampleBuffer，PTS 按 30fps 递增
        self.lastPTS = CMTimeAdd(self.lastPTS, CMTimeMake(1, 30));
        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = self.lastPTS,
            .decodeTimeStamp = self.lastPTS,
        };
        CMSampleBufferRef sb = NULL;
        OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(
            kCFAllocatorDefault, nv12,
            self.converter.formatDescription, &timing, &sb);
        CVPixelBufferRelease(nv12);
        if (st == noErr && sb) {
            [self.jitter pushSampleBuffer:sb];
            CFRelease(sb);
            [CFLogger.shared incRendered];
        }
    }
}

#pragma mark - 供 proxy 调用

- (CMSampleBufferRef)nextVideoSampleBuffer {
    return (CMSampleBufferRef)[self.jitter popRetained];   // +1 或 NULL
}

- (CMSampleBufferRef)nextAudioSampleBufferMatching:(CMSampleBufferRef)original {
    if (!original) return NULL;
    if (!self.audioReplaceEnabled) {
        CFRetain(original);
        return original;                                    // 透传
    }

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(original);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    if (!asbd) { CFRetain(original); return original; }

    CMItemCount numSamples = CMSampleBufferGetNumSamples(original);
    size_t frameBytes = asbd->mBytesPerFrame ? asbd->mBytesPerFrame
                                             : 2 * asbd->mChannelsPerFrame;
    size_t totalBytes = (size_t)numSamples * frameBytes;

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
    if (st != noErr) { CFRetain(original); return original; }
    return sb;   // +1
}

#pragma mark - 补挂 hook

- (void)rescanSessionOutputs:(AVCaptureSession *)session {
    [CFLogger.shared incSession];
    [CFLogger.shared log:@"session startRunning，补扫 outputs: %@", session.outputs];
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
