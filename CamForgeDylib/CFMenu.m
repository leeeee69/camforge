//
//  CFMenu.m
//
//  刻意从简：原版那套有图标资源、迷你图标异步下载、公告横幅。
//  自研研究版只留四个按钮 + 状态行，输入走 UIAlertController 文本框。
//

#import "CFMenu.h"
#import "CFManager.h"
#import "CFLogger.h"
#import <UIKit/UIKit.h>

static const CGFloat kPanelW = 224;
static const CGFloat kPanelH = 268;

@interface CFMenu ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *replaceButton;
@property (nonatomic, strong) UIButton *sourceButton;
@property (nonatomic, strong) UIButton *audioButton;
@property (nonatomic, assign) CFSourceType cycle;
@end

@implementation CFMenu

+ (instancetype)shared {
    static CFMenu *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [CFMenu new]; });
    return m;
}

- (instancetype)init {
    if (self = [super init]) { _cycle = CFSourceTypeSynthetic; }
    return self;
}

#pragma mark - 构建

- (void)buildIfNeeded {
    if (self.window) { [self refresh]; return; }
    UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(16, 120, kPanelW, kPanelH)];
    w.windowLevel = UIWindowLevelStatusBar + 5;      // 盖在 App UI 之上、系统弹窗之下
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [self buildPanelForWindow:w];
    w.hidden = NO;
    self.window = w;
    [self refresh];
}

- (UIViewController *)buildPanelForWindow:(UIWindow *)w {
    UIViewController *vc = [UIViewController new];
    UIVisualEffectView *bg = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    bg.frame = vc.view.bounds;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.layer.cornerRadius = 14;
    bg.layer.masksToBounds = YES;
    [vc.view addSubview:bg];

    UILabel *title = [UILabel new];
    title.text = @"CamForge (研究)";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:15];

    self.statusLabel = [UILabel new];
    self.statusLabel.text = @"...";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.statusLabel.numberOfLines = 0;

    self.replaceButton = [self buttonWithTitle:@"开始替换" action:@selector(onReplace)];
    self.sourceButton  = [self buttonWithTitle:@"视频源：合成图案" action:@selector(onSource)];
    self.audioButton   = [self buttonWithTitle:@"音频注入：关" action:@selector(onAudio)];
    UIButton *diag     = [self buttonWithTitle:@"诊断信息" action:@selector(onDiagnostics)];
    UIButton *hide     = [self buttonWithTitle:@"隐藏菜单" action:@selector(onHide)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, self.statusLabel, self.replaceButton, self.sourceButton, self.audioButton, diag, hide
    ]];
    stack.axis = UIAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-12],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPan:)];
    [vc.view addGestureRecognizer:pan];
    return vc;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 动作

- (void)onReplace {
    if (CFManager.shared.replacing) {
        [CFManager.shared stopReplacing];
    } else {
        [CFManager.shared startReplacing];
    }
    [self refresh];
}

- (void)onSource {
    // 循环：合成 → 文件 → 网络 → 合成
    self.cycle = (self.cycle + 1) % 3;
    if (self.cycle == CFSourceTypeSynthetic) {
        [CFManager.shared switchToSourceType:CFSourceTypeSynthetic urlOrPath:nil];
        [self refresh];
        return;
    }
    BOOL isFile = (self.cycle == CFSourceTypeVideoFile);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:isFile ? @"本地视频路径" : @"网络流地址"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        if (isFile) { tf.text = @"/var/mobile/Media/test.mp4"; tf.placeholder = @"/var/mobile/Media/test.mp4"; }
        else { tf.text = @"https://example.com/live.m3u8"; tf.placeholder = @"https://..."; }
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
        NSString *s = alert.textFields.firstObject.text;
        if (s.length) {
            [CFManager.shared switchToSourceType:self.cycle urlOrPath:s];
        }
        [self refresh];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)onAudio {
    CFManager.shared.audioReplaceEnabled = !CFManager.shared.audioReplaceEnabled;
    [self refresh];
}

- (void)onHide { self.window.hidden = YES; }

- (void)onDiagnostics {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CamForge 诊断"
                                                                   message:[CFLogger.shared statsText]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
    [CFLogger.shared log:@"诊断面板已打开"];
}

- (void)toggle {
    [self buildIfNeeded];
    self.window.hidden = !self.window.hidden;
    [self refresh];
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:pan.view];
    CGRect f = self.window.frame;
    f.origin.x += d.x;
    f.origin.y += d.y;
    self.window.frame = f;
    [pan setTranslation:CGPointZero inView:pan.view];
}

#pragma mark - 状态

- (void)refresh {
    if (!self.window) return;
    CFManager *m = CFManager.shared;
    self.replaceButton.backgroundColor = m.replacing
        ? [UIColor colorWithRed:0.55 green:0.15 blue:0.15 alpha:1]
        : [UIColor colorWithWhite:1 alpha:0.14];
    [self.sourceButton setTitle:[NSString stringWithFormat:@"视频源：%@",
                                 m.source.sourceName ?: @"-"]
                        forState:UIControlStateNormal];
    [self.audioButton setTitle:[NSString stringWithFormat:@"音频注入：%@",
                                m.audioReplaceEnabled ? @"开(440Hz)" : @"关"]
                       forState:UIControlStateNormal];
    self.statusLabel.text = [NSString stringWithFormat:@"替换：%@  注入帧:%lu 命中:%lu\n分辨率：%.0fx%.0f @30fps",
                             m.replacing ? @"注入中" : @"关",
                             (unsigned long)CFLogger.shared.injectedFrames,
                             (unsigned long)CFLogger.shared.videoHookHits,
                             m.outputSize.width, m.outputSize.height];
}

@end
