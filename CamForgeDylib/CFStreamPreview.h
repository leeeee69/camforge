//
//  CFStreamPreview.h — 拉流预览：先解码看画面，确认后再替换
//
//  对应原版 VCamMenuPanelView 的 previewStreamButton / showPreviewPopupForURL: /
//  startPreviewDecode: / previewTimerTick / previewPlayReplaceTapped 那一套。
//
//  设计要点：预览用**自己独立的 CFMovieSource 实例**，与注入链路完全隔离。
//  用户点「替换」时 manager 会新建一个源，两边不共享 AVFormatContext，
//  因此不存在跨线程踩同一个解码器的问题。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CFStreamPreview : NSObject

/// 打开并开始解码显示；失败时 statusText 会说明原因
- (void)startWithURL:(NSString *)url isFile:(BOOL)isFile;

/// 停止并释放（关闭弹窗时调用）
- (void)stop;

/// 状态文案（主线程读）：连接中 / 已出帧 / 无信号 / 错误原因
@property (nonatomic, copy, readonly) NSString *statusText;

/// 最近一帧（主线程读，10fps 刷新）；没有则 nil
@property (nonatomic, copy, readonly, nullable) UIImage *latestImage;

/// 是否已成功解出至少一帧
@property (nonatomic, readonly) BOOL hasFrame;

/// 预览帧率（默认 10fps，够看又不浪费）
@property (nonatomic, assign) NSUInteger previewFPS;

@end

NS_ASSUME_NONNULL_END
