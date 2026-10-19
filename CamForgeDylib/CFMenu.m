//
//  CFMenu.m — 悬浮面板的窗口层（窗口 / 气泡 / 手势 / 弹层 / 选择器 / 拉流预览）
//
//  v0.11 拆分：UI 内容全部移到 CFMenuPanelView，本文件只管窗口与模态：
//   - 面板窗口 + 折叠气泡（两个独立 UIWindow）
//   - 拖拽手势（标题栏）
//   - 弹层（诊断 / AI 话术 / 关于）+ 一键复制日志
//   - PHPicker 相册选片
//   - 拉流预览弹窗（对应原版 previewStreamButton 那一套）
//

#import "CFMenu.h"
#import "CFManager.h"
#import "CFLogger.h"
#import "CFMenuPanelView.h"
#import "CFMovieSource.h"
#import "CFExternalSource.h"
#import "CFStreamPreview.h"
#import "CFDirectSource.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import <math.h>

/// 面板尺寸（与 CFMenuPanelView 保持一致）
static const CGFloat kPanelWidth  = 320;
static const CGFloat kPanelHeight = 432;

#pragma mark - 配色（窗口层复用）

static UIColor *CFInkColor(void)  { return [UIColor colorWithRed:0.118 green:0.125 blue:0.149 alpha:1]; }
static UIColor *CFSubColor(void)  { return [UIColor colorWithRed:0.439 green:0.459 blue:0.502 alpha:1]; }
static UIColor *CFBlueColor(void) { return [UIColor colorWithRed:0.102 green:0.451 blue:0.910 alpha:1]; }

@interface CFMenu () <CFMenuPanelViewDelegate, PHPickerViewControllerDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIWindow *bubbleWindow;
@property (nonatomic, strong) CFMenuPanelView *panel;
@property (nonatomic, strong) UIView *headerHandle;     ///< 标题栏拖拽热区

@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, copy, nullable) NSString *sheetBody;

@property (nonatomic, strong) CFStreamPreview *streamPreview;
@property (nonatomic, strong) UIView *previewOverlay;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UILabel *previewStatusLabel;
@property (nonatomic, strong) CADisplayLink *previewDisplayLink;
@property (nonatomic, copy) NSString *pendingPreviewURL;

@end

@implementation CFMenu

+ (instancetype)shared {
    static CFMenu *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [CFMenu new]; });
    return m;
}

#pragma mark - 建窗

- (UIWindow *)makeWindowWithFrame:(CGRect)frame level:(UIWindowLevel)level {
    UIWindow *w = [[UIWindow alloc] initWithFrame:frame];
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                w.windowScene = (UIWindowScene *)s;
                break;
            }
        }
    }
    return w;
}

- (UIWindowScene *)activeScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (sc.activationState != UISceneActivationStateForegroundActive) continue;
            return (UIWindowScene *)sc;
        }
    }
    return nil;
}

- (void)buildIfNeeded {
    if (self.window) { [self.panel refreshState]; return; }

    // 构造器阶段 App 场景可能还没激活；退避重试，最多 20 次 × 0.5s
    if (![self activeScene]) {
        static NSInteger retries = 0;
        if (retries++ < 20) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [weakSelf buildIfNeeded]; });
        }
        return;
    }

    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat x = 12;
    CGFloat y = MAX(56, screen.height * 0.12);
    if (y + kPanelHeight > screen.height - 16) y = MAX(40, screen.height - kPanelHeight - 16);

    self.window = [self makeWindowWithFrame:CGRectMake(x, y, kPanelWidth, kPanelHeight)
                                      level:UIWindowLevelStatusBar + 10];

    self.panel = [CFMenuPanelView panel];
    self.panel.delegate = self;
    self.panel.frame = CGRectMake(0, 0, kPanelWidth, kPanelHeight);
    [self.window.rootViewController.view addSubview:self.panel];

    // 标题栏拖拽热区（面板内坐标 0..50）
    self.headerHandle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidth, 50)];
    self.headerHandle.backgroundColor = UIColor.clearColor;
    [self.headerHandle addGestureRecognizer:
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
    [self.panel addSubview:self.headerHandle];

    self.window.hidden = NO;
    [self buildBubble];
    [self.panel refreshState];
}

- (void)buildBubble {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    self.bubbleWindow = [self makeWindowWithFrame:CGRectMake(screen.width - 64, screen.height - 150, 48, 48)
                                            level:UIWindowLevelStatusBar + 10];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 48, 48);
    b.backgroundColor = CFBlueColor();
    b.layer.cornerRadius = 24;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.22;
    b.layer.shadowRadius = 6;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    [b setTitle:@"CF" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [b addTarget:self action:@selector(onBubbleTap) forControlEvents:UIControlEventTouchUpInside];
    [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onBubblePan:)]];
    [self.bubbleWindow.rootViewController.view addSubview:b];
    self.bubbleWindow.hidden = YES;
}

/// 兼容 CFManager 的旧调用：统一转到面板的显式刷新
- (void)refresh { [self.panel refreshState]; }

- (void)toggle {
    [self buildIfNeeded];
    if (!self.window) return;
    self.window.hidden = !self.window.hidden;
    if (self.window.hidden) self.bubbleWindow.hidden = NO;
    else self.bubbleWindow.hidden = YES;
    [self.panel refreshState];
}

- (void)onClose {
    self.window.hidden = YES;
    self.bubbleWindow.hidden = NO;
}

- (void)onBubbleTap {
    self.bubbleWindow.hidden = YES;
    self.window.hidden = NO;
    [self.panel refreshState];
}

- (void)onBubblePan:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:pan.view.superview];
    CGRect f = self.bubbleWindow.frame;
    f.origin.x += d.x;
    f.origin.y += d.y;
    self.bubbleWindow.frame = f;
    [pan setTranslation:CGPointZero inView:pan.view.superview];
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:pan.view];
    CGRect f = self.window.frame;
    f.origin.x += d.x;
    f.origin.y += d.y;
    self.window.frame = f;
    [pan setTranslation:CGPointZero inView:pan.view];
}

#pragma mark - CFMenuPanelViewDelegate

- (NSString *)panelAddressText {
    return self.panel.field.text ?: @"";
}

- (void)panelAddressChanged:(NSString *)text {
    CFManager.shared.lastError = nil;
}

- (void)panelDidSelectMode:(CFUiMode)mode {
    [self.panel updateUrlRowState];
    [self.panel updateActionRowState];
    [self.panel updateStatusState];
}

- (void)panelDidRequestPaste {
    NSString *s = UIPasteboard.generalPasteboard.string;
    if (s.length) {
        self.panel.field.text = s;
        CFManager.shared.lastError = nil;
    } else {
        CFManager.shared.lastError = @"剪贴板为空";
    }
    [self.panel updateStatusState];
}

- (void)panelDidRequestLoad {
    NSString *s = [self.panel.field.text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    CFManager *m = CFManager.shared;
    m.lastError = nil;

    if (self.panel.uiMode == CFUiModeDirect) {
        [m switchToSourceType:CFSourceTypeUSB urlOrPath:nil];
        [m startReplacing];
        [self.panel refreshState];
        return;
    }

    if (self.panel.uiMode == CFUiModeNetwork) {
        if (!s.length) { m.lastError = @"请先输入拉流地址"; [self.panel updateStatusState]; return; }
        NSString *lower = s.lowercaseString;
        BOOL ok = [lower hasPrefix:@"rtsp://"] || [lower hasPrefix:@"rtmp://"] ||
                  [lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"];
        if (!ok) { m.lastError = @"地址需以 rtsp:// rtmp:// http:// https:// 开头"; [self.panel updateStatusState]; return; }
        if (([lower hasPrefix:@"rtsp://"] || [lower hasPrefix:@"rtmp://"]) && ![CFMovieSource available]) {
            m.lastError = @"本 dylib 未编译 FFmpeg，RTSP/RTMP 不可用";
            [self.panel updateStatusState];
            return;
        }
        // 网络模式：先进预览看画面，确认后再替换
        [self showStreamPreviewForURL:s];
        return;
    }

    // 视频模式：留空 → 弹相册选择器
    if (!s.length) { [self presentVideoPicker]; return; }
    if (![s hasPrefix:@"/"]) {
        m.lastError = @"本地视频请填绝对路径（以 / 开头）；留空则用相册最新";
        [self.panel updateStatusState];
        return;
    }
    [m switchToSourceType:CFSourceTypeVideoFile urlOrPath:s];
    [m startReplacing];
    [self.panel refreshState];
}

- (void)panelDidRequestStop {
    [CFManager.shared stopReplacing];
    [self stopStreamPreview];
    [self.panel refreshState];
}

- (void)panelDidTapTile:(CFTileTag)tag {
    CFManager *m = CFManager.shared;
    switch (tag) {
        case CFTileApply:
            if (m.replacing) { [m stopReplacing]; }
            else { [self panelDidRequestLoad]; }
            break;
        case CFTileRotate:
            m.rotationDegrees = (m.rotationDegrees + 90) % 360;
            [m syncRenderOptions];
            break;
        case CFTileMirror:
            m.mirrored = !m.mirrored;
            [m syncRenderOptions];
            break;
        case CFTileContent:
            m.fillMode = !m.fillMode;
            [m syncRenderOptions];
            break;
        case CFTileAlpha: {
            CGFloat a = m.panelAlpha;
            a = (a > 0.95) ? 0.8 : (a > 0.75) ? 0.6 : (a > 0.55) ? 0.4 : 1.0;
            m.panelAlpha = a;
            self.panel.alpha = a;
            break;
        }
        case CFTileFrameDedupe:
            m.frameDedupe = !m.frameDedupe;
            break;
        case CFTileAudioDedupe:
            m.audioDedupe = !m.audioDedupe;
            break;
        case CFTileAudioInject:
            m.audioReplaceEnabled = !m.audioReplaceEnabled;
            break;
        default:
            break;
    }
    [CFLogger.shared log:@"面板操作 tag=%ld", (long)tag];
    [self.panel refreshState];
}

- (void)panelDidRequestClose { [self onClose]; }

- (void)panelDidRequestDiagnostics {
    [self showSheetTitle:@"诊断信息（可复制）"
                    body:[CFLogger.shared exportTextWithLines:120]];
}

- (void)panelDidRequestAiScript {
    static NSArray<NSString *> *lines;
    static NSUInteger idx = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lines = @[
            @"新进来的宝子先点个关注，福袋马上发，手慢无～",
            @"这款手串我戴了一周，洗澡都不摘，颜色一点没掉。",
            @"想要质检报告的扣 1，我一条条念给你听。",
            @"同品质外面卖 399，今天直播间 199，库存只剩最后 30 条。",
            @"别急着拍，先看清楚这颗的冰裂，我不藏瑕疵。",
            @"喜欢的左上角点关注，下播就恢复原价了。",
            @"发货都是顺丰，48 小时内出库，单号会私信给你。",
            @"不清楚尺寸的报手腕围，我帮你算圈口。",
        ];
    });
    NSMutableString *body = [NSMutableString stringWithString:@"离线内置话术（不联网，点一次换一批）:\n\n"];
    for (NSUInteger i = 0; i < 3; i++) {
        [body appendFormat:@"• %@\n\n", lines[(idx + i) % lines.count]];
    }
    idx += 3;
    [self showSheetTitle:@"AI 话术（本地）" body:body];
}

- (void)panelDidRequestAbout {
    NSString *body =
        [NSString stringWithFormat:
         @"CamForge 研究版\n"
         @"版本    : 0.11.0 (2026-10-19)\n"
         @"宿主    : %@\n"
         @"架构    : arm64 + arm64e（fat）\n"
         @"签名    : ldid\n"
         @"依赖    : CydiaSubstrate\n\n"
         @"clean-room 自研，不含授权绕过、反调试对抗、\n"
         @"平台风控对抗代码，全程零联网。\n\n"
         @"反馈：设备 syslog 里 grep [CamForge]，\n"
         @"附机型 / iOS 版本 / 复现步骤。",
         NSBundle.mainBundle.bundleIdentifier ?: @"?"];
    [self showSheetTitle:@"更新 & 反馈" body:body];
}

#pragma mark - 弹层

- (void)showSheetTitle:(NSString *)title body:(NSString *)body {
    [self.sheet removeFromSuperview];

    UIView *s = [[UIView alloc] initWithFrame:self.panel.bounds];
    s.backgroundColor = [UIColor colorWithRed:0.973 green:0.973 blue:0.980 alpha:0.98];
    s.layer.cornerRadius = 16;
    s.layer.masksToBounds = YES;

    UILabel *t = [self label:title size:13.5 weight:UIFontWeightSemibold color:CFInkColor()];
    t.frame = CGRectMake(14, 14, kPanelWidth - 14 * 2 - 40, 20);
    [s addSubview:t];

    UIButton *x = [self roundButton:@"xmark" sel:@selector(onDismissSheet)];
    x.frame = CGRectMake(kPanelWidth - 14 - 26, 12, 26, 26);
    [s addSubview:x];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeCustom];
    copy.frame = CGRectMake(kPanelWidth - 14 - 26 - 34, 12, 30, 26);
    [copy setImage:[UIImage systemImageNamed:@"doc.on.doc"
                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13
                                                                                            weight:UIImageSymbolWeightSemibold]]
          forState:UIControlStateNormal];
    copy.tintColor = CFSubColor();
    copy.backgroundColor = [UIColor colorWithRed:0.945 green:0.949 blue:0.961 alpha:1];
    copy.layer.cornerRadius = 13;
    [copy addTarget:self action:@selector(onCopySheetBody) forControlEvents:UIControlEventTouchUpInside];
    [s addSubview:copy];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(14, 42, kPanelWidth - 28, kPanelHeight - 42 - 14)];
    tv.backgroundColor = UIColor.clearColor;
    tv.editable = NO;
    tv.selectable = YES;
    tv.text = body;
    tv.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    tv.textColor = CFInkColor();
    [s addSubview:tv];

    [self.panel addSubview:s];
    self.sheet = s;
    self.sheetBody = body;
}

- (void)onDismissSheet {
    [self.sheet removeFromSuperview];
    self.sheet = nil;
}

- (void)onCopySheetBody {
    if (self.sheetBody.length == 0) return;
    UIPasteboard.generalPasteboard.string = self.sheetBody;
    [CFLogger.shared log:@"日志已复制到剪贴板（%lu 字节）", (unsigned long)self.sheetBody.length];
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    return l;
}

- (UIButton *)roundButton:(NSString *)symbol sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:[UIImage systemImageNamed:symbol
                       withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14
                                                                                         weight:UIImageSymbolWeightSemibold]]
        forState:UIControlStateNormal];
    b.tintColor = CFSubColor();
    b.backgroundColor = [UIColor colorWithRed:0.945 green:0.949 blue:0.961 alpha:1];
    b.layer.cornerRadius = 13;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 相册选片（PHPicker）

static UIViewController *cf_top_view_controller(void) {
    UIWindow *key = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        if (sc.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        key = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)presentVideoPicker {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = PHPickerFilter.videosFilter;
    cfg.selectionLimit = 1;
    cfg.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;

    UIViewController *host = cf_top_view_controller();
    if (!host) {
        CFManager.shared.lastError = @"找不到可挂载的控制器，改用相册最新";
        [CFManager.shared switchToSourceType:CFSourceTypeAlbum urlOrPath:nil];
        [CFManager.shared startReplacing];
        [self.panel refreshState];
        return;
    }
    self.window.hidden = YES;
    [host presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{
        self.window.hidden = NO;
        [self.panel refreshState];
    }];
    if (results.count == 0) return;

    NSItemProvider *provider = results.firstObject.itemProvider;
    NSString *type = @"public.movie";
    if (![provider hasItemConformingToTypeIdentifier:type]) type = @"public.video";

    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:type
                                    completionHandler:^(NSURL *url, NSError *error) {
        NSError *copyErr = nil;
        NSString *dst = nil;
        if (url) {
            NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
            dst = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"cf_pick.%@", ext]];
            [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
            if (![[NSFileManager defaultManager] copyItemAtURL:url
                                                         toURL:[NSURL fileURLWithPath:dst]
                                                         error:&copyErr]) {
                dst = nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            if (!dst) {
                CFManager.shared.lastError = copyErr.localizedDescription ?: @"选中的视频读不出来";
                [self_.panel updateStatusState];
                return;
            }
            CFManager.shared.lastError = nil;
            [CFManager.shared switchToSourceType:CFSourceTypeVideoFile urlOrPath:dst];
            [CFManager.shared startReplacing];
            [self_.panel refreshState];
            [CFLogger.shared log:@"相册选片: %@", dst];
        });
    }];
}

#pragma mark - 拉流预览弹窗

- (void)showStreamPreviewForURL:(NSString *)url {
    [self stopStreamPreview];
    self.pendingPreviewURL = url;

    CGFloat w = kPanelWidth - 28;
    UIView *ov = [[UIView alloc] initWithFrame:self.panel.bounds];
    ov.backgroundColor = [UIColor colorWithRed:0.973 green:0.973 blue:0.980 alpha:0.98];
    ov.layer.cornerRadius = 16;
    ov.layer.masksToBounds = YES;

    UILabel *title = [self label:@"拉流预览" size:13.5 weight:UIFontWeightSemibold color:CFInkColor()];
    title.frame = CGRectMake(14, 12, w - 40, 20);
    [ov addSubview:title];

    UIButton *x = [self roundButton:@"xmark" sel:@selector(onClosePreview)];
    x.frame = CGRectMake(kPanelWidth - 14 - 26, 10, 26, 26);
    [ov addSubview:x];

    UIView *imgBox = [[UIView alloc] initWithFrame:CGRectMake(14, 44, w, 176)];
    imgBox.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    imgBox.layer.cornerRadius = 8;
    imgBox.clipsToBounds = YES;
    [ov addSubview:imgBox];

    self.previewImageView = [[UIImageView alloc] initWithFrame:imgBox.bounds];
    self.previewImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.previewImageView.backgroundColor = UIColor.clearColor;
    [imgBox addSubview:self.previewImageView];

    UILabel *ph = [self label:@"等待画面…" size:11 weight:UIFontWeightRegular
                       color:[UIColor colorWithWhite:0.6 alpha:1]];
    ph.tag = 9001;
    ph.frame = CGRectMake(0, 0, imgBox.bounds.size.width, 20);
    ph.center = imgBox.center;
    [imgBox addSubview:ph];

    self.previewStatusLabel = [self label:@"连接中…" size:10 weight:UIFontWeightRegular color:CFSubColor()];
    self.previewStatusLabel.frame = CGRectMake(14, 226, w, 14);
    self.previewStatusLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    [ov addSubview:self.previewStatusLabel];

    UIButton *replace = [UIButton buttonWithType:UIButtonTypeCustom];
    replace.frame = CGRectMake(14, 250, w, 36);
    replace.backgroundColor = CFBlueColor();
    replace.layer.cornerRadius = 9;
    [replace setTitle:@"替换相机" forState:UIControlStateNormal];
    [replace setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    replace.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [replace addTarget:self action:@selector(onPreviewReplace) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:replace];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.frame = CGRectMake(14, 294, w, 32);
    cancel.backgroundColor = [UIColor colorWithRed:0.945 green:0.949 blue:0.961 alpha:1];
    cancel.layer.cornerRadius = 8;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:CFInkColor() forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [cancel addTarget:self action:@selector(onClosePreview) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:cancel];

    [self.panel addSubview:ov];
    self.previewOverlay = ov;

    self.streamPreview = [CFStreamPreview new];
    [self.streamPreview startWithURL:url isFile:NO];

    self.previewDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onPreviewTick)];
    self.previewDisplayLink.preferredFramesPerSecond = 10;
    [self.previewDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    [CFLogger.shared log:@"拉流预览打开: %@", url];
}

- (void)onPreviewTick {
    CFStreamPreview *p = self.streamPreview;
    if (!p) return;

    self.previewStatusLabel.text = p.statusText;
    UIImage *img = p.latestImage;
    if (img && img != self.previewImageView.image) {
        self.previewImageView.image = img;
        UIView *ph = [self.previewImageView.superview viewWithTag:9001];
        ph.hidden = YES;
    }
}

- (void)onPreviewReplace {
    NSString *url = self.pendingPreviewURL;
    if (url.length == 0) { [self onClosePreview]; return; }

    CFManager.shared.lastError = nil;
    [CFManager.shared switchToSourceType:CFSourceTypeNetwork urlOrPath:url];
    [CFManager.shared startReplacing];
    [self onClosePreview];
    [self.panel refreshState];
    [CFLogger.shared log:@"预览确认，开始替换: %@", url];
}

- (void)onClosePreview {
    [self.previewDisplayLink invalidate];
    self.previewDisplayLink = nil;
    [self.streamPreview stop];
    self.streamPreview = nil;
    [self.previewOverlay removeFromSuperview];
    self.previewOverlay = nil;
    self.previewImageView = nil;
    self.previewStatusLabel = nil;
    self.pendingPreviewURL = nil;
}

- (void)stopStreamPreview {
    if (self.previewOverlay) { [self onClosePreview]; }
}

@end
