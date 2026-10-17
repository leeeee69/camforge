//
//  CFHooks.m — 独立 dylib 入口：进程 guard + MSHookMessageEx 显式 hook
//
//  与 tweak 版（Tweak.xm + Logos %hook）的区别：
//  1. 不用 Logos，直接用 MSHookMessageEx——dylib 可被任何加载器加载
//  2. 构造器先查 bundle id，非目标进程直接 inert（防止 insert_dylib /
//     DYLD_INSERT_LIBRARIES 方式下污染其他 App）
//
//  支持多个宿主（2026-10-18）：filter plist 里列出的每个 bundle 都会加载本 dylib，
//  这里也必须放行同一份白名单，否则微信里 dylib 加载了却不建面板（表现为"微信没 UI"）。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import "CFManager.h"
#import "CFCaptureProxy.h"
#import "CFLogger.h"
#import "CFMenu.h"

/// 目标进程 bundle id 白名单。改这里 + libCamForge.plist 的 Filter/Bundles
/// 两处要同步，否则会「加载了但不干活」。
static NSArray<NSString *> *cf_targetBundleIDs(void) {
    static NSArray<NSString *> *ids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ids = @[
            @"com.ss.iphone.ugc.Aweme",   // 抖音
            @"com.tencent.xin",           // 微信
        ];
    });
    return ids;
}

#pragma mark - hook 实现（trampoline）

static void (*g_origVideoSetDelegate)(id, SEL, id, dispatch_queue_t);
static void hookVideoSetDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    g_origVideoSetDelegate(self, _cmd, delegate, queue);
    // delegate 为 nil 表示 App 正在拆输出：此时绝不能把代理塞回去（queue 也可能是 nil）
    if (!delegate) return;
    if (![delegate isKindOfClass:[CFCaptureProxy class]]) {
        [CFCaptureProxy wrapVideoOutput:(AVCaptureVideoDataOutput *)self];
    }
}

static void (*g_origAudioSetDelegate)(id, SEL, id, dispatch_queue_t);
static void hookAudioSetDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    g_origAudioSetDelegate(self, _cmd, delegate, queue);
    if (!delegate) return;
    if (![delegate isKindOfClass:[CFCaptureProxy class]]) {
        [CFCaptureProxy wrapAudioOutput:(AVCaptureAudioDataOutput *)self];
    }
}

/// 按类型包装某个 output（幂等）
static void cf_wrap_output(AVCaptureOutput *o) {
    if ([o isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        [CFCaptureProxy wrapVideoOutput:(AVCaptureVideoDataOutput *)o];
    } else if ([o isKindOfClass:[AVCaptureAudioDataOutput class]]) {
        [CFCaptureProxy wrapAudioOutput:(AVCaptureAudioDataOutput *)o];
    }
}

static void (*g_origAddOutput)(id, SEL, AVCaptureOutput *);
static void hookAddOutput(id self, SEL _cmd, AVCaptureOutput *output) {
    g_origAddOutput(self, _cmd, output);
    if (!output) return;

    @try {
        cf_wrap_output(output);
        // 时序兜底：不少 App 是 addOutput → 稍后 setSampleBufferDelegate，
        // 这里补两次延迟重试（包装本身幂等，重复调用无害）。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ cf_wrap_output(output); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ cf_wrap_output(output); });
    } @catch (NSException *e) {
        [CFLogger.shared log:@"addOutput 包装异常: %@", e.reason];
    }
}

static void (*g_origStartRunning)(id, SEL);
static void hookStartRunning(id self, SEL _cmd) {
    g_origStartRunning(self, _cmd);
    @try {
        [[CFManager shared] rescanSessionOutputs:(AVCaptureSession *)self];
    } @catch (NSException *e) {
        [CFLogger.shared log:@"补扫 outputs 异常: %@", e.reason];
    }
}

static void cf_install(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

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
    // addOutput 补挂：output 可能在 startRunning 之后才加进来
    MSHookMessageEx(objc_getClass("AVCaptureSession"),
                    @selector(addOutput:),
                    (IMP)hookAddOutput, (IMP *)&g_origAddOutput);
    [CFLogger.shared log:@"MSHookMessageEx hooks installed"];
}

#pragma mark - 构造器

__attribute__((constructor))
static void cf_load() {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        if (![cf_targetBundleIDs() containsObject:bid]) {
            return;   // 非目标进程：不 hook、不建窗，dylib 完全 inert
        }
        [CFLogger.shared log:@"loaded into %@, installing hooks", bid];
        [CFLogger.shared log:@"log file: %@", [CFLogger.shared logFilePath]];
        dispatch_async(dispatch_get_main_queue(), ^{
            cf_install();
            [[CFMenu shared] buildIfNeeded];
        });
    }
}
