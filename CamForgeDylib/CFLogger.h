//
//  CFLogger.h — 诊断埋点：hook 命中计数 + 事件流水（研究实验用）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CFLogger : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSUInteger videoHookHits;    ///< 视频输出回调命中次数
@property (nonatomic, readonly) NSUInteger audioHookHits;    ///< 音频输出回调命中次数
@property (nonatomic, readonly) NSUInteger injectedFrames;   ///< 实际注入的假帧数
@property (nonatomic, readonly) NSUInteger passthroughFrames;///< 透传的真帧数
@property (nonatomic, readonly) NSUInteger renderedFrames;   ///< 渲染线程产出的帧数
@property (nonatomic, readonly) NSUInteger sessionsSeen;     ///< 见过的 session 数
@property (nonatomic, readonly) NSUInteger directAudioFrames;  ///< 用推流音频替换的次数

- (void)incVideoHookHit;
- (void)incAudioHookHit;
- (void)incInjected;
- (void)incPassthrough;
- (void)incRendered;
- (void)incSession;
- (void)incDirectAudio;

/// 同时写 NSLog（设备 syslog / Console.app 可见）和内存事件流水
- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// 诊断面板文案：计数 + 最近 12 条事件
- (NSString *)statsText;

/// 日志文件绝对路径（在宿主 App 沙盒的 Caches/CamForge 下；崩溃后仍保留）
- (NSString *)logFilePath;

/// 日志文件最后 n 行（文件读不到时回落到内存流水）
- (NSString *)tailLines:(NSUInteger)n;

/// 面板「复制日志」用：路径 + 统计 + 最近 n 行
- (NSString *)exportTextWithLines:(NSUInteger)n;

@end

NS_ASSUME_NONNULL_END
