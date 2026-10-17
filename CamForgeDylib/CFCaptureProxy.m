//
//  CFCaptureProxy.m
//

#import "CFCaptureProxy.h"
#import "CFManager.h"
#import "CFLogger.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

@implementation CFCaptureProxy

+ (void)wrapVideoOutput:(AVCaptureVideoDataOutput *)output {
    CFCaptureProxy *proxy = objc_getAssociatedObject(output, @selector(wrapVideoOutput:));
    if (!proxy) {
        proxy = [CFCaptureProxy new];
        objc_setAssociatedObject(output, @selector(wrapVideoOutput:), proxy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id current = output.sampleBufferDelegate;
    if (current != proxy) {
        // 先记住 App 的真 delegate，再把代理塞进去
        // （iOS 17 SDK 起 sampleBufferDelegate 为 readonly，必须走 setSampleBufferDelegate:queue:；
        //   queue 沿用 App 原先那个，回调线程不变）
        proxy.videoOriginal = current;
        [output setSampleBufferDelegate:proxy queue:output.sampleBufferCallbackQueue];
        // 会再次进入被 hook 的 setter，此时 delegate 已是 proxy，直接透传
        [CFLogger.shared log:@"video delegate 已包装: %@ -> %@", current, output];
    }
}

+ (void)wrapAudioOutput:(AVCaptureAudioDataOutput *)output {
    CFCaptureProxy *proxy = objc_getAssociatedObject(output, @selector(wrapAudioOutput:));
    if (!proxy) {
        proxy = [CFCaptureProxy new];
        objc_setAssociatedObject(output, @selector(wrapAudioOutput:), proxy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id current = output.sampleBufferDelegate;
    if (current != proxy) {
        proxy.audioOriginal = current;
        [output setSampleBufferDelegate:proxy queue:output.sampleBufferCallbackQueue];
        [CFLogger.shared log:@"audio delegate 已包装: %@ -> %@", current, output];
    }
}

#pragma mark - 输出回调

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    BOOL isVideo = [output isKindOfClass:[AVCaptureVideoDataOutput class]];
    id original = isVideo ? self.videoOriginal : self.audioOriginal;
    if (![original respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [CFLogger.shared log:@"%@: 无真 delegate，丢弃", isVideo ? @"video" : @"audio"];
        return;
    }

    if (isVideo) { [CFLogger.shared incVideoHookHit]; } else { [CFLogger.shared incAudioHookHit]; }

    CMSampleBufferRef injected = isVideo
        ? [CFManager.shared nextVideoSampleBuffer]
        : [CFManager.shared nextAudioSampleBufferMatching:sampleBuffer];

    CMSampleBufferRef deliver = injected ? injected : sampleBuffer;
    if (injected) { [CFLogger.shared incInjected]; } else { [CFLogger.shared incPassthrough]; }
    [original captureOutput:output didOutputSampleBuffer:deliver fromConnection:connection];
    if (injected) CFRelease(injected);
}

@end
