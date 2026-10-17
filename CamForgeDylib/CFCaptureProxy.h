//
//  CFCaptureProxy.h — 委托代理：替换相机输出回调里的 sample buffer
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CFCaptureProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate,
                                      AVCaptureAudioDataOutputSampleBufferDelegate>

/// App 原来的 delegate。必须 strong：output 只保证"弱持有"语义的地方，
/// 一旦 App 释放自己的 delegate，weak 引用变 nil 后回调就断了（表现为黑屏/无帧）。
@property (nonatomic, strong, nullable) id videoOriginal;
@property (nonatomic, strong, nullable) id audioOriginal;

/// 给 output 挂上代理（幂等；delegate 被换人时自动改指向新 delegate）
+ (void)wrapVideoOutput:(AVCaptureVideoDataOutput *)output;
+ (void)wrapAudioOutput:(AVCaptureAudioDataOutput *)output;

@end

NS_ASSUME_NONNULL_END
