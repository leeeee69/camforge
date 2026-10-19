//
//  CFMenuPanelView.m — 面板内容视图实现
//

#import "CFMenuPanelView.h"
#import "CFManager.h"
#import "CFLogger.h"
#import "CFMovieSource.h"
#import "CFExternalSource.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat kPanelW = 320;
static const CGFloat kPad    = 14;
static const CGFloat kPanelH = 432;
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

@interface CFMenuPanelView () <UITextFieldDelegate>

@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *urlLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIButton *loadButton;

@property (nonatomic, strong) NSMutableArray<UIButton *> *modeButtons;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CFTileButton *> *tiles;

@end

@implementation CFMenuPanelView

+ (instancetype)panel {
    return [[self alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = CFCardBG();
        self.layer.cornerRadius = 16;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = CFLine().CGColor;
        _uiMode = CFUiModeVideo;
        _modeButtons = [NSMutableArray array];
        _tiles = [NSMutableDictionary dictionary];

        [self buildHeader];
        [self buildHint];
        [self buildModeSegment];
        [self buildUrlRow];
        [self buildActionRow];
        [self buildGrid];
        [self buildWideRow];
        [self buildStatus];
    }
    return self;
}

#pragma mark - 构建

- (void)buildHeader {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kHeaderH)];
    h.backgroundColor = UIColor.clearColor;
    self.header = h;
    [self addSubview:h];

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

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH - 0.5, kPanelW, 0.5)];
    sep.backgroundColor = CFLine();
    [self addSubview:sep];
}

- (void)buildHint {
    self.hintLabel = [self label:@"填地址后点「加载」，循环注入；「停止」恢复真实相机"
                            size:11 weight:UIFontWeightRegular color:CFSub()];
    self.hintLabel.numberOfLines = 2;
    self.hintLabel.frame = CGRectMake(kPad, kHintY, kPanelW - kPad * 2, kHintH);
    [self addSubview:self.hintLabel];
}

- (void)buildModeSegment {
    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(kPad, kSegY, kPanelW - kPad * 2, kSegH)];
    track.backgroundColor = CFTileBG();
    track.layer.cornerRadius = 9;
    [self addSubview:track];

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
    self.urlLabel = [self label:@"🎬  本地视频（点「加载」从相册选）"
                            size:11.5 weight:UIFontWeightMedium color:CFSub()];
    self.urlLabel.frame = CGRectMake(kPad, kUrlY, kPanelW - kPad * 2, kUrlH);
    [self addSubview:self.urlLabel];

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(kPad, kFieldY, kPanelW - kPad * 2, kFieldH)];
    box.backgroundColor = CFTileBG();
    box.layer.cornerRadius = 9;
    [self addSubview:box];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(10, 0, box.bounds.size.width - 20, kFieldH)];
    self.field.font = [UIFont systemFontOfSize:11.5];
    self.field.textColor = CFInk();
    self.field.placeholder = @"留空即可：点「加载」弹出相册选视频";
    self.field.keyboardType = UIKeyboardTypeURL;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.spellCheckingType = UITextSpellCheckingTypeNo;
    self.field.returnKeyType = UIReturnKeyDone;
    self.field.delegate = self;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing;
    [self.field addTarget:self action:@selector(onAddressChanged:) forControlEvents:UIControlEventEditingChanged];
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
        [self addSubview:b];
        if (primary) self.loadButton = b;
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
        [self addSubview:b];
    }
    for (NSInteger i = 0; i < row2.count; i++) {
        NSArray *a = row2[i];
        CFTileButton *b = [self tileWithTitle:a[0] symbol:a[1] tag:[a[2] integerValue]];
        b.frame = CGRectMake(kPad + i * (kTileW + kTileGap), kGrid2Y, kTileW, kGridH);
        [self addSubview:b];
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
        [self addSubview:b];
    }
}

- (void)buildStatus {
    self.statusLabel = [self label:@"状态：待机" size:9.5 weight:UIFontWeightRegular color:CFSub()];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    self.statusLabel.frame = CGRectMake(kPad, kStatusY, kPanelW - kPad * 2, kStatusH);
    self.statusLabel.userInteractionEnabled = YES;
    [self.statusLabel addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDiagnostics)]];
    [self addSubview:self.statusLabel];
}

#pragma mark - 工厂

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

#pragma mark - 动作（转交 delegate）

- (void)onMode:(UIButton *)sender {
    self.uiMode = (CFUiMode)sender.tag;
    [CFManager.shared stopReplacing];
    [self updateModeSegmentState];
    [self updateUrlRowState];
    if ([self.delegate respondsToSelector:@selector(panelDidSelectMode:)]) {
        [self.delegate panelDidSelectMode:self.uiMode];
    }
}

- (void)onAddressChanged:(UITextField *)sender {
    if ([self.delegate respondsToSelector:@selector(panelAddressChanged:)]) {
        [self.delegate panelAddressChanged:sender.text ?: @""];
    }
}

- (void)onPaste {
    if ([self.delegate respondsToSelector:@selector(panelDidRequestPaste)]) {
        [self.delegate panelDidRequestPaste];
    }
}

- (void)onLoad {
    if ([self.delegate respondsToSelector:@selector(panelDidRequestLoad)]) {
        [self.delegate panelDidRequestLoad];
    }
}

- (void)onStop {
    if ([self.delegate respondsToSelector:@selector(panelDidRequestStop)]) {
        [self.delegate panelDidRequestStop];
    }
}

- (void)onTile:(CFTileButton *)sender {
    if ([self.delegate respondsToSelector:@selector(panelDidTapTile:)]) {
        [self.delegate panelDidTapTile:(CFTileTag)sender.tag];
    }
}

- (void)onDiagnostics {
    if ([self.delegate respondsToSelector:@selector(panelDidRequestDiagnostics)]) {
        [self.delegate panelDidRequestDiagnostics];
    }
}

- (void)onAiScript {
    if ([self.delegate respondsToSelector:@selector(panelDidRequestAiScript)]) {
        [self.delegate panelDidRequestAiScript];
    }
}

- (void)onAbout {
    if ([self.delegate respondsToSelector:@selector(panelDidRequestAbout)]) {
        [self.delegate panelDidRequestAbout];
    }
}

- (void)onClose {
    if ([self.delegate respondsToSelector:@selector(panelDidRequestClose)]) {
        [self.delegate panelDidRequestClose];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - 状态刷新（显式收敛，一个控件一个方法）

- (void)refreshState {
    [self updateModeSegmentState];
    [self updateUrlRowState];
    [self updateActionRowState];
    for (NSNumber *k in self.tiles) {
        [self updateTileState:(CFTileTag)k.integerValue];
    }
    [self updateStatusState];
}

- (void)updateModeSegmentState {
    for (UIButton *b in self.modeButtons) {
        BOOL on = ((CFUiMode)b.tag == self.uiMode);
        b.backgroundColor = on ? UIColor.whiteColor : UIColor.clearColor;
        [b setTitleColor:(on ? CFBlue() : CFSub()) forState:UIControlStateNormal];
        b.layer.shadowOpacity = on ? 0.10 : 0.0;
        b.layer.shadowRadius = on ? 2.0 : 0.0;
        b.layer.shadowOffset = CGSizeMake(0, 1);
    }
}

- (void)updateUrlRowState {
    if (self.uiMode == CFUiModeNetwork) {
        self.urlLabel.text = @"🌐  拉流地址（RTSP / RTMP / FLV / HLS）";
        self.field.placeholder = @"rtsp:// | rtmp:// | http(s)://…";
        self.hintLabel.text = [CFMovieSource available]
            ? @"填地址点「加载」→ 先弹预览看画面，确认后再点「替换」。"
            : @"本构建未含 FFmpeg：RTSP/RTMP/FLV 不可用，仅 http(s)/HLS。";
    } else if (self.uiMode == CFUiModeDirect) {
        self.urlLabel.text = @"🔌  直连（USB 数据线 · usbmuxd 推送）";
        self.field.placeholder = @"此模式不用地址：手机监听 127.0.0.1:9527";
        self.hintLabel.text = @"PC 上 iproxy 9527 9527 后跑 tools/cf-push.py，帧实时推给手机。";
    } else {
        self.urlLabel.text = @"🎬  本地视频（点「加载」从相册选）";
        self.field.placeholder = @"留空即可：点「加载」弹出相册选视频";
        self.hintLabel.text = @"点「加载」从相册挑一条视频，循环注入；也可在上面粘绝对路径。";
    }
}

- (void)updateActionRowState {
    // 加载按钮文案随模式变：网络模式强调"先预览"
    NSString *title = (self.uiMode == CFUiModeNetwork) ? @"⬇ 预览" : @"⬇ 加载";
    [self.loadButton setTitle:title forState:UIControlStateNormal];
}

- (void)updateTileState:(CFTileTag)tag {
    CFManager *m = CFManager.shared;
    CFTileButton *b = self.tiles[@(tag)];
    if (!b) return;

    switch (tag) {
        case CFTileApply:
            [b applyTitle:(m.replacing ? @"停止替屏" : @"应用替屏")
                   symbol:@"bolt.fill" on:m.replacing];
            break;
        case CFTileRotate:
            [b applyTitle:[NSString stringWithFormat:@"旋转·%ld°", (long)m.rotationDegrees]
                   symbol:@"rotate.right" on:(m.rotationDegrees != 0)];
            break;
        case CFTileMirror:
            [b applyTitle:@"画面镜像" symbol:@"arrow.left.arrow.right" on:m.mirrored];
            break;
        case CFTileContent:
            [b applyTitle:(m.fillMode ? @"内容·填充" : @"内容·适应")
                   symbol:@"rectangle.inset.filled" on:!m.fillMode];
            break;
        case CFTileAlpha:
            [b applyTitle:[NSString stringWithFormat:@"透明·%d%%", (int)lround(m.panelAlpha * 100)]
                   symbol:@"circle.lefthalf.filled" on:(m.panelAlpha < 0.95)];
            break;
        case CFTileFrameDedupe:
            [b applyTitle:@"画面去重" symbol:@"square.stack.3d.up" on:m.frameDedupe];
            b.badge.hidden = !m.frameDedupe;
            break;
        case CFTileAudioDedupe:
            [b applyTitle:@"音频去重" symbol:@"waveform" on:m.audioDedupe];
            break;
        case CFTileAudioInject:
            [b applyTitle:(m.audioReplaceEnabled ? @"音频·开" : @"音频注入")
                   symbol:@"speaker.wave.2.fill" on:m.audioReplaceEnabled];
            break;
        default:
            break;
    }
}

- (void)updateStatusState {
    CFManager *m = CFManager.shared;
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
}

@end
