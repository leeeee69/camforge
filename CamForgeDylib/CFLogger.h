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

@end

NS_ASSUME_NONNULL_END
