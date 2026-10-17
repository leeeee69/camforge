//
//  CFMenu.m — 悬浮控制面板
//
//  布局按参考面板的层级重做：标题栏 / 提示 / 直播模式分段 / 拉流地址 /
//  粘贴-加载-停止 / 功能网格（2×4）/ AI 话术-更新反馈 / 状态行。
//  视觉走浅色卡片（旧版是深色毛玻璃，与参考差距大）。
//
//  所有功能本地实现，全程不联网：
//    应用替屏 = 加载当前输入并开始注入（注入中则停止）
//    旋转     = 0/90/180/270 顺时针
//    画面镜像 = 水平翻转
//    内容     = 填充 / 适应
//    透明     = 面板透明度 100/80/60/40%
//    画面去重 = 内容摘要相同则不重复注入
//    音频去重 = 注入音频摘要相同则跳过
//    音频注入 = 440Hz 标记音（默认关）
//    AI 话术  = 内置离线话术轮播（不联网、不调模型）
//    更新&反馈 = 版本信息与反馈说明（不联网）
//

#import "CFMenu.h"
#import "CFManager.h"
#import "CFLogger.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat kPanelW  = 320;
static const CGFloat kPad     = 14;
static const CGFloat kPanelH  = 432;
static const CGFloat kTileGap = 6;
static const CGFloat kTileW   = 68;

static const CGFloat kHeaderH = 50;
static const CGFloat kHintY   = 52, kHintH   = 30;
static const CGFloat kSegY    = 84, kSegH    = 30;
static const CGFloat kUrlY    = 120, kUrlH   = 18;
static const CGFloat kFieldY  = 140, kFieldH = 34;
static const CGFloat kBtnY    = 184, kBtnH   = 34;
static const CGFloat kGrid1Y  = 226, kGridH  = 60;
static const CGFloat kGrid2Y  = 292;
static const CGFloat kWideY   = 358, kWideH  = 36;
static const CGFloat kStatusY = 400, kStatusH = 18;

#pragma mark - 配色

static UIColor *CFCardBG(void)   { return [UIColor colorWithRed:0.973 green:0.973 blue:0.980 alpha:0.98]; }
static UIColor *CFTileBG(void)   { return [UIColor colorWithRed:0.945 green:0.949 blue:0.961 alpha:1.0]; }
static UIColor *CFTileBGOn(void) { return [UIColor colorWithRed:0.902 green:0.937 blue:0.996 alpha:1.0]; }
static UIColor *CFBlue(void)     { return [UIColor colorWithRed:0.102 green:0.451 blue:0.910 alpha:1.0]; }
static UIColor *CFGreen(void)    { return [UIColor colorWithRed:0.129 green:0.659 blue:0.329 alpha:1.0]; }
static UIColor *CFInk(void)      { return [UIColor colorWithRed:0.118 green:0.125 blue:0.149 alpha:1.0]; }
static UIColor *CFSub(void)      { return [UIColor colorWithRed:0.439 green:0.459 blue:0.502 alpha:1.0]; }
static UIColor *CFLine(void)     { return [UIColor colorWithRed:0.898 green:0.910 blue:0.929 alpha:1.0]; }
static UIColor *CFWarn(void)     { return [UIColor colorWithRed:0.780 green:0.360 blue:0.110 alpha:1.0]; }

#pragma mark - 功能格控件

typedef NS_ENUM(NSInteger, CFTileTag) {
    CFTileApply = 100,
    CFTileRotate,
    CFTileMirror,
    CFTileContent,
    CFTileAlpha,
    CFTileFrameDedupe,
    CFTileAudioDedupe,
    CFTileAudioInject,
};

/// 图标在上、文字在下的小方块。不用 UIButtonConfiguration：那套在
/// setTitle:forState: 与 configuration 混用时标题会不刷新（踩过）。
@interface CFTileButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UILabel *badge;
- (void)applyTitle:(NSString *)title symbol:(NSString *)symbol on:(BOOL)on;
@end

@implementation CFTileButton

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = CFTileBG();
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1;
        self.layer.borderColor = UIColor.clearColor.CGColor;

        CGFloat w = frame.size.width;
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake((w - 22) / 2.0, 9, 22, 22)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];

        _textLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, 33, w - 4, 14)];
        _textLabel.textAlignment = NSTextAlignmentCenter;
        _textLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _textLabel.userInteractionEnabled = NO;
        [self addSubview:_textLabel];

        _badge = [[UILabel alloc] initWithFrame:CGRectMake(w - 19, 4, 14, 14)];
        _badge.backgroundColor = CFGreen();
        _badge.textColor = UIColor.whiteColor;
        _badge.text = @"✓";
        _badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.layer.cornerRadius = 7;
        _badge.layer.masksToBounds = YES;
        _badge.hidden = YES;
        _badge.userInteractionEnabled = NO;
        [self addSubview:_badge];
    }
    return self;
}

- (void)applyTitle:(NSString *)title symbol:(NSString *)symbol on:(BOOL)on {
    self.backgroundColor = on ? CFTileBGOn() : CFTileBG();
    self.layer.borderColor = on ? CFBlue().CGColor : UIColor.clearColor.CGColor;
    UIColor *fg = on ? CFBlue() : CFInk();
    self.iconView.image = [UIImage systemImageNamed:symbol
                                  withConfiguration:[UIImageSymbolConfiguration
                                                     configurationWithPointSize:17
                                                                       weight:UIImageSymbolWeightMedium]];
    self.iconView.tintColor = fg;
    self.textLabel.text = title;
    self.textLabel.textColor = fg;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1.0;
}

@end

#pragma mark - 面板

typedef NS_ENUM(NSInteger, CFUiMode) {
    CFUiModeVideo = 0,
    CFUiModeNetwork,
    CFUiModeDirect,
};

@interface CFMenu () <UITextFieldDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIWindow *bubbleWindow;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *header;

@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *urlLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *field;

@property (nonatomic, strong) NSMutableArray<UIButton *> *modeButtons;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CFTileButton *> *tiles;
@property (nonatomic, strong) UIView *sheet;

@property (nonatomic, assign) CFUiMode uiMode;

- (void)setTile:(CFTileTag)tag title:(NSString *)title on:(BOOL)on;
- (NSString *)symbolForTag:(CFTileTag)tag;

@end

@implementation CFMenu

+ (instancetype)shared {
    static CFMenu *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [CFMenu new]; });
    return m;
}

- (instancetype)init {
    if ((self = [super init])) {
        _uiMode = CFUiModeVideo;
        _modeButtons = [NSMutableArray array];
        _tiles = [NSMutableDictionary dictionary];
    }
    return self;
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

- (void)buildIfNeeded {
    if (self.window) { [self refresh]; return; }

    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat x = 12;
    CGFloat y = MAX(56, screen.height * 0.12);
    if (y + kPanelH > screen.height - 16) y = MAX(40, screen.height - kPanelH - 16);

    self.window = [self makeWindowWithFrame:CGRectMake(x, y, kPanelW, kPanelH)
                                      level:UIWindowLevelStatusBar + 10];
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
    self.panel.backgroundColor = CFCardBG();
    self.panel.layer.cornerRadius = 16;
    self.panel.layer.masksToBounds = YES;
    self.panel.layer.borderWidth = 0.5;
    self.panel.layer.borderColor = CFLine().CGColor;
    [self.window.rootViewController.view addSubview:self.panel];

    [self buildHeader];
    [self buildHint];
    [self buildModeSegment];
    [self buildUrlRow];
    [self buildActionRow];
    [self buildGrid];
    [self buildWideRow];
    [self buildStatus];

    self.window.hidden = NO;
    [self buildBubble];
    [self refresh];
}

- (void)buildHeader {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kHeaderH)];
    h.backgroundColor = UIColor.clearColor;
    self.header = h;
    [self.panel addSubview:h];

    UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(kPad, 14, 24, 24)];
    icon.backgroundColor = CFBlue();
    icon.layer.cornerRadius = 7;
    UIImageView *iv = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"video.fill"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12
                                                                                  weight:UIImageSymbolWeightBold]]];
    iv.tintColor = UIColor.whiteColor;
    iv.frame = CGRectMake(5, 5, 14, 14);
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [icon addSubview:iv];
    [h addSubview:icon];

    UILabel *title = [self label:@"CamForge" size:15 weight:UIFontWeightSemibold color:CFInk()];
    title.frame = CGRectMake(46, 12, 130, 20);
    [h addSubview:title];

    UILabel *tag = [self label:@"研究版 · 虚拟相机" size:9 weight:UIFontWeightRegular color:CFSub()];
    tag.frame = CGRectMake(46, 30, 160, 12);
    [h addSubview:tag];

    UIButton *info = [self roundButton:@"info.circle" sel:@selector(onDiagnostics)];
    info.frame = CGRectMake(kPanelW - kPad - 26 - 32, 12, 26, 26);
    [h addSubview:info];

    UIButton *close = [self roundButton:@"xmark" sel:@selector(onClose)];
    close.frame = CGRectMake(kPanelW - kPad - 26, 12, 26, 26);
    [h addSubview:close];

    [h addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH - 0.5, kPanelW, 0.5)];
    sep.backgroundColor = CFLine();
    [self.panel addSubview:sep];
}

- (void)buildHint {
    self.hintLabel = [self label:@"填地址后点「加载」，循环注入；「停止」恢复真实相机"
                            size:11 weight:UIFontWeightRegular color:CFSub()];
    self.hintLabel.numberOfLines = 2;
    self.hintLabel.frame = CGRectMake(kPad, kHintY, kPanelW - kPad * 2, kHintH);
    [self.panel addSubview:self.hintLabel];
}

- (void)buildModeSegment {
    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(kPad, kSegY, kPanelW - kPad * 2, kSegH)];
    track.backgroundColor = CFTileBG();
    track.layer.cornerRadius = 9;
    [self.panel addSubview:track];

    NSArray<NSString *> *names = @[@"视频", @"网络", @"直连"];
    CGFloat w = (kPanelW - kPad * 2) / 3.0;
    for (NSInteger i = 0; i < names.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(i * w, 0, w, kSegH);
        b.tag = i;
        [b setTitle:names[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 7;
        [b addTarget:self action:@selector(onMode:) forControlEvents:UIControlEventTouchUpInside];
        [track addSubview:b];
        [self.modeButtons addObject:b];
    }
}

- (void)buildUrlRow {
    self.urlLabel = [self label:@"🎬  本地视频路径" size:11.5 weight:UIFontWeightMedium color:CFSub()];
    self.urlLabel.frame = CGRectMake(kPad, kUrlY, kPanelW - kPad * 2, kUrlH);
    [self.panel addSubview:self.urlLabel];

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(kPad, kFieldY, kPanelW - kPad * 2, kFieldH)];
    box.backgroundColor = CFTileBG();
    box.layer.cornerRadius = 9;
    [self.panel addSubview:box];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(10, 0, box.bounds.size.width - 20, kFieldH)];
    self.field.font = [UIFont systemFontOfSize:11.5];
    self.field.textColor = CFInk();
    self.field.placeholder = @"/var/mobile/Media/test.mp4";
    self.field.keyboardType = UIKeyboardTypeURL;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.spellCheckingType = UITextSpellCheckingTypeNo;
    self.field.returnKeyType = UIReturnKeyDone;
    self.field.delegate = self;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing;
    [box addSubview:self.field];
}

- (void)buildActionRow {
    CGFloat total = kPanelW - kPad * 2;
    CGFloat gap = 8;
    CGFloat w = (total - gap * 2) / 3.0;
    NSArray<NSString *> *titles = @[@"📋 粘贴", @"⬇ 加载", @"⏹ 停止"];
    NSArray<NSString *> *sels = @[NSStringFromSelector(@selector(onPaste)),
                                  NSStringFromSelector(@selector(onLoad)),
                                  NSStringFromSelector(@selector(onStop))];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(kPad + i * (w + gap), kBtnY, w, kBtnH);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 8;
        BOOL primary = (i == 1);
        b.backgroundColor = primary ? CFBlue() : CFTileBG();
        [b setTitleColor:(primary ? UIColor.whiteColor : CFInk()) forState:UIControlStateNormal];
        [b addTarget:self action:NSSelectorFromString(sels[i]) forControlEvents:UIControlEventTouchUpInside];
        [self.panel addSubview:b];
    }
}

- (void)buildGrid {
    NSArray<NSArray *> *row1 = @[
        @[@"应用替屏", @"bolt.fill",              @(CFTileApply)],
        @[@"旋转",     @"rotate.right",           @(CFTileRotate)],
        @[@"画面镜像", @"arrow.left.arrow.right", @(CFTileMirror)],
        @[@"内容",     @"rectangle.inset.filled", @(CFTileContent)],
    ];
    NSArray<NSArray *> *row2 = @[
        @[@"透明",     @"circle.lefthalf.filled", @(CFTileAlpha)],
        @[@"画面去重", @"square.stack.3d.up",     @(CFTileFrameDedupe)],
        @[@"音频去重", @"waveform",               @(CFTileAudioDedupe)],
        @[@"音频注入", @"speaker.wave.2.fill",    @(CFTileAudioInject)],
    ];
    for (NSInteger i = 0; i < row1.count; i++) {
        NSArray *a = row1[i];
        CFTileButton *b = [self tileWithTitle:a[0] symbol:a[1] tag:[a[2] integerValue]];
        b.frame = CGRectMake(kPad + i * (kTileW + kTileGap), kGrid1Y, kTileW, kGridH);
        [self.panel addSubview:b];
    }
    for (NSInteger i = 0; i < row2.count; i++) {
        NSArray *a = row2[i];
        CFTileButton *b = [self tileWithTitle:a[0] symbol:a[1] tag:[a[2] integerValue]];
        b.frame = CGRectMake(kPad + i * (kTileW + kTileGap), kGrid2Y, kTileW, kGridH);
        [self.panel addSubview:b];
    }
}

- (void)buildWideRow {
    CGFloat total = kPanelW - kPad * 2;
    CGFloat gap = 8;
    CGFloat w = (total - gap) / 2.0;
    NSArray<NSString *> *titles = @[@"💬  AI 话术", @"⬆  更新&反馈"];
    NSArray<NSString *> *sels = @[NSStringFromSelector(@selector(onAiScript)),
                                  NSStringFromSelector(@selector(onAbout))];
    for (NSInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(kPad + i * (w + gap), kWideY, w, kWideH);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
        b.backgroundColor = CFTileBG();
        b.layer.cornerRadius = 8;
        [b setTitleColor:CFInk() forState:UIControlStateNormal];
        [b addTarget:self action:NSSelectorFromString(sels[i]) forControlEvents:UIControlEventTouchUpInside];
        [self.panel addSubview:b];
    }
}

- (void)buildStatus {
    self.statusLabel = [self label:@"状态：待机" size:9.5 weight:UIFontWeightRegular color:CFSub()];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    self.statusLabel.frame = CGRectMake(kPad, kStatusY, kPanelW - kPad * 2, kStatusH);
    self.statusLabel.userInteractionEnabled = YES;
    [self.statusLabel addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDiagnostics)]];
    [self.panel addSubview:self.statusLabel];
}

- (void)buildBubble {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    self.bubbleWindow = [self makeWindowWithFrame:CGRectMake(screen.width - 64, screen.height - 150, 48, 48)
                                            level:UIWindowLevelStatusBar + 10];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 48, 48);
    b.backgroundColor = CFBlue();
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

#pragma mark - 控件工厂

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 1;
    return l;
}

- (UIButton *)roundButton:(NSString *)symbol sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:[UIImage systemImageNamed:symbol
                       withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14
                                                                                         weight:UIImageSymbolWeightSemibold]]
        forState:UIControlStateNormal];
    b.tintColor = CFSub();
    b.backgroundColor = CFTileBG();
    b.layer.cornerRadius = 13;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (CFTileButton *)tileWithTitle:(NSString *)title symbol:(NSString *)symbol tag:(NSInteger)tag {
    CFTileButton *b = [[CFTileButton alloc] initWithFrame:CGRectMake(0, 0, kTileW, kGridH)];
    b.tag = tag;
    [b applyTitle:title symbol:symbol on:NO];
    [b addTarget:self action:@selector(onTile:) forControlEvents:UIControlEventTouchUpInside];
    self.tiles[@(tag)] = b;
    return b;
}

#pragma mark - 动作

- (void)onMode:(UIButton *)sender {
    self.uiMode = (CFUiMode)sender.tag;
    if (self.uiMode == CFUiModeDirect) {
        [CFManager.shared stopReplacing];
        [CFManager.shared switchToSourceType:CFSourceTypeDirect urlOrPath:nil];
    }
    [self refresh];
}

- (void)onPaste {
    NSString *s = UIPasteboard.generalPasteboard.string;
    if (s.length) {
        self.field.text = s;
        CFManager.shared.lastError = nil;
    } else {
        CFManager.shared.lastError = @"剪贴板为空";
    }
    [self refresh];
}

- (void)onLoad {
    NSString *s = [self.field.text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    CFManager *m = CFManager.shared;

    if (self.uiMode == CFUiModeDirect) {
        [m switchToSourceType:CFSourceTypeDirect urlOrPath:nil];
        [self refresh];
        return;
    }
    if (!s.length) {
        m.lastError = @"请先输入地址或视频路径";
        [self refresh];
        return;
    }

    if (self.uiMode == CFUiModeNetwork) {
        NSString *lower = s.lowercaseString;
        if ([lower hasPrefix:@"rtsp://"] || [lower hasPrefix:@"rtmp://"]) {
            m.lastError = @"RTSP/RTMP 需 FFmpeg，本工程未内置，请用 http(s)/m3u8/mp4";
            [self refresh];
            return;
        }
        if (![lower hasPrefix:@"http://"] && ![lower hasPrefix:@"https://"]) {
            m.lastError = @"网络模式需要 http(s) 地址";
            [self refresh];
            return;
        }
        m.lastError = nil;
        [m switchToSourceType:CFSourceTypeNetwork urlOrPath:s];
        [m startReplacing];
    } else {
        if (![s hasPrefix:@"/"]) {
            m.lastError = @"本地视频请填绝对路径（以 / 开头）";
            [self refresh];
            return;
        }
        m.lastError = nil;
        [m switchToSourceType:CFSourceTypeVideoFile urlOrPath:s];
        [m startReplacing];
    }
    [self refresh];
}

- (void)onStop {
    [CFManager.shared stopReplacing];
    [self refresh];
}

- (void)onTile:(CFTileButton *)sender {
    CFManager *m = CFManager.shared;
    switch ((CFTileTag)sender.tag) {
        case CFTileApply:
            if (m.replacing) {
                [m stopReplacing];
            } else {
                [self onLoad];
            }
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
    [CFLogger.shared log:@"面板操作: %@", sender.textLabel.text];
    [self refresh];
}

- (void)onClose {
    self.window.hidden = YES;
    self.bubbleWindow.hidden = NO;
}

- (void)onBubbleTap {
    self.bubbleWindow.hidden = YES;
    self.window.hidden = NO;
    [self refresh];
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

#pragma mark - 弹层（不走 presentViewController，避免非层级 VC 弹窗崩溃）

- (void)showSheetTitle:(NSString *)title body:(NSString *)body {
    [self.sheet removeFromSuperview];

    UIView *s = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
    s.backgroundColor = CFCardBG();
    s.layer.cornerRadius = 16;
    s.layer.masksToBounds = YES;

    UILabel *t = [self label:title size:13.5 weight:UIFontWeightSemibold color:CFInk()];
    t.frame = CGRectMake(kPad, 14, kPanelW - kPad * 2 - 40, 20);
    [s addSubview:t];

    UIButton *x = [self roundButton:@"xmark" sel:@selector(onDismissSheet)];
    x.frame = CGRectMake(kPanelW - kPad - 26, 12, 26, 26);
    [s addSubview:x];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(kPad, 42, kPanelW - kPad * 2, kPanelH - 42 - kPad)];
    tv.backgroundColor = UIColor.clearColor;
    tv.editable = NO;
    tv.selectable = YES;
    tv.text = body;
    tv.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    tv.textColor = CFInk();
    [s addSubview:tv];

    [self.panel addSubview:s];
    self.sheet = s;
}

- (void)onDismissSheet {
    [self.sheet removeFromSuperview];
    self.sheet = nil;
}

- (void)onDiagnostics {
    [self showSheetTitle:@"诊断信息" body:[CFLogger.shared statsText]];
}

- (void)onAiScript {
    // 完全离线：内置话术轮播，不联网、不调任何模型
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

- (void)onAbout {
    NSString *body =
        [NSString stringWithFormat:
         @"CamForge 研究版\n"
         @"版本    : 0.3.0 (2026-10-18)\n"
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

#pragma mark - 文本输入

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    [self.window makeKeyWindow];   // 非 key window 收不到键盘输入
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - 状态刷新

- (void)refresh {
    if (!self.window) return;
    CFManager *m = CFManager.shared;

    // 模式分段
    for (UIButton *b in self.modeButtons) {
        BOOL on = ((CFUiMode)b.tag == self.uiMode);
        b.backgroundColor = on ? UIColor.whiteColor : UIColor.clearColor;
        [b setTitleColor:(on ? CFBlue() : CFSub()) forState:UIControlStateNormal];
        b.layer.shadowOpacity = on ? 0.10 : 0.0;
        b.layer.shadowRadius = on ? 2.0 : 0.0;
        b.layer.shadowOffset = CGSizeMake(0, 1);
    }

    // 地址行随模式变
    if (self.uiMode == CFUiModeNetwork) {
        self.urlLabel.text = @"🌐  网络拉流地址";
        self.field.placeholder = @"http(s):// … .m3u8 / .mp4";
        self.hintLabel.text = @"支持 http(s)/HLS/mp4；RTSP·RTMP 需 FFmpeg，本版未内置。";
    } else if (self.uiMode == CFUiModeDirect) {
        self.urlLabel.text = @"🔌  直连（相机透传，不注入）";
        self.field.placeholder = @"此模式无需地址，用于 A/B 对照";
        self.hintLabel.text = @"直连模式把真实相机原样交给 App，用来对照注入效果。";
    } else {
        self.urlLabel.text = @"🎬  本地视频路径";
        self.field.placeholder = @"/var/mobile/Media/test.mp4";
        self.hintLabel.text = @"填本地视频绝对路径后点「加载」，循环播放并注入。";
    }

    // 功能格
    [self setTile:CFTileApply title:(m.replacing ? @"停止替屏" : @"应用替屏") on:m.replacing];
    [self setTile:CFTileRotate
            title:[NSString stringWithFormat:@"旋转·%ld°", (long)m.rotationDegrees]
               on:(m.rotationDegrees != 0)];
    [self setTile:CFTileMirror title:@"画面镜像" on:m.mirrored];
    [self setTile:CFTileContent title:(m.fillMode ? @"内容·填充" : @"内容·适应") on:!m.fillMode];
    [self setTile:CFTileAlpha
            title:[NSString stringWithFormat:@"透明·%d%%", (int)lround(m.panelAlpha * 100)]
               on:(m.panelAlpha < 0.95)];
    [self setTile:CFTileFrameDedupe title:@"画面去重" on:m.frameDedupe];
    [self setTile:CFTileAudioDedupe title:@"音频去重" on:m.audioDedupe];
    [self setTile:CFTileAudioInject
            title:(m.audioReplaceEnabled ? @"音频·开" : @"音频注入")
               on:m.audioReplaceEnabled];

    CFTileButton *dedupeTile = self.tiles[@(CFTileFrameDedupe)];
    if (dedupeTile) dedupeTile.badge.hidden = !m.frameDedupe;

    // 状态行
    if (m.lastError.length) {
        self.statusLabel.text = [NSString stringWithFormat:@"⚠️ %@", m.lastError];
        self.statusLabel.textColor = CFWarn();
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"%@ · 帧 %lu · 命中 %lu · %.0f×%.0f",
                                 m.replacing ? @"注入中" : @"待机",
                                 (unsigned long)CFLogger.shared.injectedFrames,
                                 (unsigned long)CFLogger.shared.videoHookHits,
                                 m.outputSize.width, m.outputSize.height];
        self.statusLabel.textColor = CFSub();
    }
    self.panel.alpha = m.panelAlpha;
}

- (void)setTile:(CFTileTag)tag title:(NSString *)title on:(BOOL)on {
    CFTileButton *b = self.tiles[@(tag)];
    if (!b) return;
    [b applyTitle:title symbol:[self symbolForTag:tag] on:on];
}

- (NSString *)symbolForTag:(CFTileTag)tag {
    switch (tag) {
        case CFTileApply:       return @"bolt.fill";
        case CFTileRotate:      return @"rotate.right";
        case CFTileMirror:      return @"arrow.left.arrow.right";
        case CFTileContent:     return @"rectangle.inset.filled";
        case CFTileAlpha:       return @"circle.lefthalf.filled";
        case CFTileFrameDedupe: return @"square.stack.3d.up";
        case CFTileAudioDedupe: return @"waveform";
        case CFTileAudioInject: return @"speaker.wave.2.fill";
    }
    return @"circle";
}

#pragma mark - 显示切换

- (void)toggle {
    [self buildIfNeeded];
    self.window.hidden = !self.window.hidden;
    if (self.window.hidden) self.bubbleWindow.hidden = NO;
    else self.bubbleWindow.hidden = YES;
    [self refresh];
}

@end
