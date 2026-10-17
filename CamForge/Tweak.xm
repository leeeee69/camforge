//
//  Tweak.xm — CamForge 入口：hook AVCapture 输出链路
//
//  hook 策略（与原版工具同一技术族，但这里是自研实现）：
//  1. hook -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
//     / -[AVCaptureAudioDataOutput setSampleBufferDelegate:queue:]
//     App 每次设置 delegate 后，把代理对象换进去（App 的真 delegate 被代理记住并转发）。
//  2. hook -[AVCaptureSession startRunning] 做一次补扫，防止 delegate 在插件加载前已设好。
//

#import <AVFoundation/AVFoundation.h>
#import "CFManager.h"
#import "CFCaptureProxy.h"

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if ([delegate isKindOfClass:[CFCaptureProxy class]]) {
        %orig;                      // 代理自身回设，直接透传，防重入
        return;
    }
    %orig;                          // 先让系统存下 App 的真 delegate
    [CFCaptureProxy wrapVideoOutput:self];
}

%end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if ([delegate isKindOfClass:[CFCaptureProxy class]]) {
        %orig;
        return;
    }
    %orig;
    [CFCaptureProxy wrapAudioOutput:self];
}

%end

%hook AVCaptureSession

- (void)startRunning {
    %orig;
    [[CFManager shared] rescanSessionOutputs:self];
}

%end

%ctor {
    // 等 App 主界面起来后再建悬浮窗，避免 window scene 未就绪
    dispatch_async(dispatch_get_main_queue(), ^{
        [[CFMenu shared] buildIfNeeded];
    });
}
