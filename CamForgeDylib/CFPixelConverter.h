//
//  CFPixelConverter.h — BGRA → 目标像素格式转换（CoreImage 管线）
//
//  关键点：输出的像素格式必须与目标 App 给 AVCaptureVideoDataOutput 配的
//  videoSettings 一致。抖音/微信这类 App 若配的是 BGRA，我们硬塞 NV12，
//  它按平面访问（GetBaseAddressOfPlane）会拿到 NULL 直接崩。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface CFPixelConverter : NSObject

/// 输出像素格式：kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange（默认）/
/// kCVPixelFormatType_420YpCbCr8BiPlanarFullRange / kCVPixelFormatType_32BGRA
@property (nonatomic, assign) OSType targetPixelFormat;

/// 顺时针旋转角度，仅支持 0 / 90 / 180 / 270（其他值按 0 处理）
@property (nonatomic, assign) NSInteger rotationDegrees;

/// 水平镜像
@property (nonatomic, assign) BOOL mirrored;

/// YES = 填充（等比放大裁切，默认）；NO = 适应（等比缩小留黑边）
@property (nonatomic, assign) BOOL fillMode;

/// 最近一帧的输出尺寸（含旋转后的交换）
@property (nonatomic, readonly) CGSize outputSize;

/// 最近一帧的 format description（+0，不要释放；无帧返回 NULL）
@property (nonatomic, readonly, nullable) CMVideoFormatDescriptionRef formatDescription;

/// src 为 BGRA，返回目标格式的 pixel buffer（+1，调用方释放）；失败返回 NULL
- (nullable CVPixelBufferRef)convertBGRA:(CVPixelBufferRef)src;

@end

NS_ASSUME_NONNULL_END
