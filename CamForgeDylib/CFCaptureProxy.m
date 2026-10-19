//
//  CFCaptureProxy.m
//
//  2026-10-18 崩溃修复：
//   1) App 拆除时常用 setSampleBufferDelegate:nil queue:nil 清空输出。若此时仍把
//      代理塞回去（queue=nil），AVFoundation 会抛 NSInvalidArgumentException 直接崩。
//      → delegate 为空或 queue 为空时一律跳过包装。
//   2) 顺手把 output.videoSettings 的像素格式同步给 CFManager，保证出帧格式一致；
//      抖音/微信若配的是 BGRA，我们吐 NV12，它按平面取地址会拿 NULL 崩。
//   3) 回调里对下游调用加异常兜底：注入帧被下游拒时回退真帧再试一次。
//

#import "CFCaptureProxy.h"
#import "CFManager.h"
#import "CFLogger.h"
#import <math.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

/// 连接上的画面旋转角（0/90/180/270）。iOS 17 起用 videoRotationAngle，
/// 老 API videoOrientation 在 17 SDK 已废弃，直接引用会被 -Werror 拦，故用 pragma 压掉。
static NSInteger cf_connection_rotation(AVCaptureConnection *c) {
    if (!c) return 0;
    if (@available(iOS 17.0, *)) {
        return (NSInteger)(lround(c.videoRotationAngle / 90.0) * 90);
    }
    // videoOrientation + 相关枚举在 17 SDK 已废弃；-Werror 下必须整段压掉
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSInteger deg = 0;
    switch (c.videoOrientation) {
        case AVCaptureVideoOrientationPortraitUpsideDown: deg = 180; break;
        case AVCaptureVideoOrientationLandscapeRight:     deg = 270; break;
        case AVCaptureVideoOrientationLandscapeLeft:      deg = 90;  break;
        default:                                          deg = 0;   break;
    }
#pragma clang diagnostic pop
    return deg;
}

static BOOL cf_connection_mirrored(AVCaptureConnection *c) {
    if (!c) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL m = c.isVideoMirrored;
#pragma clang diagnostic pop
    return m;
}

@implementation CFCaptureProxy

+ (void)wrapVideoOutput:(AVCaptureVideoDataOutput *)output {
    if (!output) return;

    // 先同步目标像素格式（即便 delegate 已成代理，格式也可能被 App 重配）
    [CFManager.shared noteVideoOutputSettings:output.videoSettings];

    id current = output.sampleBufferDelegate;
    if (!current) return;                               // 未设 / 刚被清空：等下一次 setter
    if ([current isKindOfClass:[CFCaptureProxy class]]) return;

    dispatch_queue_t q = output.sampleBufferCallbackQueue;
    if (!q) {
        [CFLogger.shared log:@"video output 无 callback queue，跳过包装（避免 nil queue 崩溃）"];
        return;
    }

    CFCaptureProxy *proxy = objc_getAssociatedObject(output, @selector(wrapVideoOutput:));
    if (!proxy) {
        proxy = [CFCaptureProxy new];
        objc_setAssociatedObject(output, @selector(wrapVideoOutput:), proxy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    proxy.videoOriginal = current;                      // 先记住真 delegate，再换人
    // iOS 17 SDK 起 sampleBufferDelegate 为 readonly，必须走 setter；
    // queue 沿用 App 原先那个，回调线程不变。
    [output setSampleBufferDelegate:proxy queue:q];
    [CFLogger.shared log:@"video delegate 已包装: %@", NSStringFromClass([current class])];
}

+ (void)wrapAudioOutput:(AVCaptureAudioDataOutput *)output {
    if (!output) return;

    id current = output.sampleBufferDelegate;
    if (!current) return;
    if ([current isKindOfClass:[CFCaptureProxy class]]) return;

    dispatch_queue_t q = output.sampleBufferCallbackQueue;
    if (!q) {
        [CFLogger.shared log:@"audio output 无 callback queue，跳过包装"];
        return;
    }

    CFCaptureProxy *proxy = objc_getAssociatedObject(output, @selector(wrapAudioOutput:));
    if (!proxy) {
        proxy = [CFCaptureProxy new];
        objc_setAssociatedObject(output, @selector(wrapAudioOutput:), proxy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    proxy.audioOriginal = current;
    [output setSampleBufferDelegate:proxy queue:q];
    [CFLogger.shared log:@"audio delegate 已包装: %@", NSStringFromClass([current class])];
}

#pragma mark - 输出回调

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        if (!sampleBuffer) return;

        BOOL isVideo = [output isKindOfClass:[AVCaptureVideoDataOutput class]];
        id original = isVideo ? self.videoOriginal : self.audioOriginal;
        if (!original ||
            ![original respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [CFLogger.shared incPassthrough];
            return;
        }

        if (isVideo) { [CFLogger.shared incVideoHookHit]; }
        else         { [CFLogger.shared incAudioHookHit]; }

        // 首帧：读真实 buffer 的像素格式（videoSettings 可能为 nil/滞后，实际格式才算数），
        // 并把 connection 的朝向/镜像记下来 —— 这两项对不上会表现为画面方向错乱。
        if (isVideo) {
            static BOOL loggedOnce = NO;
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pb) {
                OSType fmt = CVPixelBufferGetPixelFormatType(pb);
                [CFManager.shared noteIncomingPixelFormat:fmt];
                if (!loggedOnce) {
                    loggedOnce = YES;
                    [CFLogger.shared log:@"首帧: %zux%zu fmt=0x%x 朝向=%ld 镜像=%d",
                        CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), fmt,
                        (long)cf_connection_rotation(connection), cf_connection_mirrored(connection)];
                }
            }
        }

        CMSampleBufferRef injected = NULL;
        @try {
            injected = isVideo
                ? [CFManager.shared nextVideoSampleBufferMatching:sampleBuffer]
                : [CFManager.shared nextAudioSampleBufferMatching:sampleBuffer];
        } @catch (NSException *e) {
            [CFLogger.shared log:@"取注入帧异常: %@", e.reason];
            injected = NULL;
        }

        CMSampleBufferRef deliver = injected ? injected : sampleBuffer;
        if (injected) { [CFLogger.shared incInjected]; }
        else          { [CFLogger.shared incPassthrough]; }

        __block BOOL ok = NO;
        @try {
            [original captureOutput:output didOutputSampleBuffer:deliver fromConnection:connection];
            ok = YES;
        } @catch (NSException *e) {
            [CFLogger.shared log:@"下游处理注入帧异常: %@", e.reason];
        }
        // 注入帧被下游拒（格式/时长不合它意）时，回退真帧再喂一次，避免直接黑屏
        if (!ok && injected) {
            @try {
                [original captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            } @catch (NSException *e2) {
                [CFLogger.shared log:@"回退真帧仍异常，本帧丢弃: %@", e2.reason];
            }
        }
        if (injected) CFRelease(injected);
    }
}

@end
