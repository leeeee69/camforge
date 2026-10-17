//
//  CFHooks.m — 独立 dylib 入口：进程 guard + MSHookMessageEx 显式 hook
//
//  与 tweak 版（Tweak.xm + Logos %hook）的区别：
//  1. 不用 Logos，直接用 MSHookMessageEx——dylib 可被任何加载器加载
//  2. 构造器先查 bundle id，非目标进程直接 inert（防止 insert_dylib /
//     DYLD_INSERT_LIBRARIES 方式下污染其他 App）
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import "CFManager.h"
#import "CFCaptureProxy.h"
#import "CFLogger.h"
#import "CFMenu.h"

/// 目标进程 bundle id（抖音）。改这里即可换目标。
static NSString *const kTargetBundleID = @"com.ss.iphone.ugc.Aweme";

#pragma mark - hook 实现（trampoline）

static void (*g_origVideoSetDelegate)(id, SEL, id, dispatch_queue_t);
static void hookVideoSetDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    g_origVideoSetDelegate(self, _cmd, delegate, queue);
    if (![delegate isKindOfClass:[CFCaptureProxy class]]) {
        [CFCaptureProxy wrapVideoOutput:(AVCaptureVideoDataOutput *)self];
    }
}

static void (*g_origAudioSetDelegate)(id, SEL, id, dispatch_queue_t);
static void hookAudioSetDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    g_origAudioSetDelegate(self, _cmd, delegate, queue);
    if (![delegate isKindOfClass:[CFCaptureProxy class]]) {
        [CFCaptureProxy wrapAudioOutput:(AVCaptureAudioDataOutput *)self];
    }
}

static void (*g_origStartRunning)(id, SEL);
static void hookStartRunning(id self, SEL _cmd) {
    g_origStartRunning(self, _cmd);
    [[CFManager shared] rescanSessionOutputs:(AVCaptureSession *)self];
}

static void cf_install(void) {
    // setSampleBufferDelegate:queue: — App 每次设 delegate 后把代理换进去
    MSHookMessageEx(objc_getClass("AVCaptureVideoDataOutput"),
                    @selector(setSampleBufferDelegate:queue:),
                    (IMP)hookVideoSetDelegate, (IMP *)&g_origVideoSetDelegate);
    MSHookMessageEx(objc_getClass("AVCaptureAudioDataOutput"),
                    @selector(setSampleBufferDelegate:queue:),
                    (IMP)hookAudioSetDelegate, (IMP *)&g_origAudioSetDelegate);
    // startRunning 补扫：防 delegate 在 hook 安装前已设好 / session 被重建
    MSHookMessageEx(objc_getClass("AVCaptureSession"),
                    @selector(startRunning),
                    (IMP)hookStartRunning, (IMP *)&g_origStartRunning);
    [CFLogger.shared log:@"MSHookMessageEx hooks installed"];
}

#pragma mark - 构造器

__attribute__((constructor))
static void cf_load() {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        if (![bid isEqualToString:kTargetBundleID]) {
            return;   // 非目标进程：不 hook、不建窗，dylib 完全 inert
        }
        [CFLogger.shared log:@"loaded into %@, installing hooks", bid];
        dispatch_async(dispatch_get_main_queue(), ^{
            cf_install();
            [[CFMenu shared] buildIfNeeded];
        });
    }
}
