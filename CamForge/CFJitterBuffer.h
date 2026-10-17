//
//  CFJitterBuffer.h — 4 帧环形缓冲（渲染线程写 / 相机回调线程读）
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface CFJitterBuffer : NSObject

- (void)pushSampleBuffer:(CMSampleBufferRef)sb;   ///< 内部 retain；满则丢最旧
- (nullable CMSampleBufferRef)popRetained;        ///< 取最新一帧（+1），空则 NULL
- (void)drain;

@end

NS_ASSUME_NONNULL_END
