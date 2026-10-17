//
//  CFPixelConverter.h — BGRA → NV12 转换（CoreImage 管线）
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface CFPixelConverter : NSObject

/// src 为 BGRA，返回 NV12（+1，调用方释放）；失败返回 NULL
- (nullable CVPixelBufferRef)convertBGRA:(CVPixelBufferRef)src;

/// NV12 format description（首次转换后可用，不要释放）
- (nullable CMVideoFormatDescriptionRef)formatDescription;

@end

NS_ASSUME_NONNULL_END
