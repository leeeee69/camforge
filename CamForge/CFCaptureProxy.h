//
//  CFCaptureProxy.h — 委托代理：替换相机输出回调里的 sample buffer
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CFCaptureProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate,
                                      AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic, weak, nullable) id videoOriginal;   ///< App 原来的视频 delegate
@property (nonatomic, weak, nullable) id audioOriginal;   ///< App 原来的音频 delegate

/// 给 output 挂上代理（幂等；delegate 被换人时自动改指向新 delegate）
+ (void)wrapVideoOutput:(AVCaptureVideoDataOutput *)output;
+ (void)wrapAudioOutput:(AVCaptureAudioDataOutput *)output;

@end

NS_ASSUME_NONNULL_END
