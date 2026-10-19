//
//  CFMenuPanelView.h — 悬浮面板的内容视图（按钮/输入/网格/状态行）
//
//  拆分动机（对照原版 VCamMenuPanelView）：
//   1. 原版把面板拆成 Controller（窗口/手势）+ PanelView（内容）+ DirectPreviewView；
//      我们原来是单类 800 行，功能继续加会难维护。
//   2. 原版每个按钮都有配对的 updateXxxButtonState，状态刷新显式收敛；
//      我们原来只有一个 refresh() 兜底。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CFUiMode) {
    CFUiModeVideo = 0,
    CFUiModeNetwork,
    CFUiModeDirect,
};

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

@protocol CFMenuPanelViewDelegate <NSObject>
- (nullable NSString *)panelAddressText;
- (void)panelAddressChanged:(NSString *)text;
- (void)panelDidRequestLoad;
- (void)panelDidRequestStop;
- (void)panelDidRequestPaste;
- (void)panelDidSelectMode:(CFUiMode)mode;
- (void)panelDidTapTile:(CFTileTag)tag;
- (void)panelDidRequestDiagnostics;
- (void)panelDidRequestAiScript;
- (void)panelDidRequestAbout;
- (void)panelDidRequestClose;      ///< 标题栏 ✕
@end

@interface CFMenuPanelView : UIView

@property (nonatomic, weak) id<CFMenuPanelViewDelegate> delegate;
@property (nonatomic, assign) CFUiMode uiMode;

/// 供窗口层读取/回填（地址输入框、主操作按钮）
@property (nonatomic, strong, readonly) UITextField *field;
@property (nonatomic, strong, readonly) UIButton *loadButton;

+ (instancetype)panel;

/// 统一状态刷新入口；内部逐个控件走显式的 updateXxxState
- (void)refreshState;

- (void)updateModeSegmentState;
- (void)updateUrlRowState;
- (void)updateActionRowState;
- (void)updateTileState:(CFTileTag)tag;
- (void)updateStatusState;

@end

NS_ASSUME_NONNULL_END
