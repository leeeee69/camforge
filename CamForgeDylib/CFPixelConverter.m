//
//  CFPixelConverter.m — 用 CIContext render 到 NV12 buffer pool
//
//  为什么选 CoreImage 而不是手写 NEON：色彩矩阵（BT.601/709）、range 转换
//  全交给系统，少一类隐蔽 bug；研究目的下性能足够（1080p 实测跟得上 30fps）。
//

#import "CFPixelConverter.h"
#import <CoreImage/CoreImage.h>

@implementation CFPixelConverter {
    CVPixelBufferPoolRef _pool;
    CGSize _poolSize;
    CIContext *_ci;
    CGColorSpaceRef _rgb;
    CMVideoFormatDescriptionRef _fmt;
}

- (instancetype)init {
    if (self = [super init]) {
        _ci = [CIContext contextWithOptions:nil];
        _rgb = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_fmt) CFRelease(_fmt);
    CGColorSpaceRelease(_rgb);
}

- (void)ensurePoolForSize:(CGSize)size {
    if (_pool && CGSizeEqualToSize(_poolSize, size)) return;
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
    _poolSize = size;
    NSDictionary *props = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey:  @(size.width),
        (id)kCVPixelBufferHeightKey: @(size.height),
    };
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)props, &_pool);
}

- (CVPixelBufferRef)convertBGRA:(CVPixelBufferRef)src {
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    [self ensurePoolForSize:CGSizeMake(w, h)];
    if (!_pool) return NULL;

    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }
    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    [_ci render:img toCVPixelBuffer:dst bounds:img.extent colorSpace:_rgb];
    if (!_fmt) {
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, dst, &_fmt);
    }
    return dst;   // +1
}

- (CMVideoFormatDescriptionRef)formatDescription { return _fmt; }

@end
