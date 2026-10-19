//
//  CFPixelConverter.m — 用 CIContext render 到目标格式 buffer pool
//
//  为什么选 CoreImage 而不是手写 NEON：色彩矩阵（BT.601/709）、range 转换
//  全交给系统，少一类隐蔽 bug；旋转/镜像/填充也顺手做了。
//
//  历史坑（2026-10-18 修）：format description 只在首次转换时建一次，之后
//  换分辨率/换像素格式都不重建 —— 一旦源视频尺寸变化，描述与实际 buffer
//  不匹配，CMSampleBufferCreateReadyWithImageBuffer 失败；调用方若拿到过
//  一次错配的 buffer，下游按错误布局解析就会崩。
//

#import "CFPixelConverter.h"
#import <CoreImage/CoreImage.h>
#import <math.h>

@implementation CFPixelConverter {
    CVPixelBufferPoolRef _pool;
    CGSize _poolSize;
    OSType _poolFormat;
    CIContext *_ci;
    CGColorSpaceRef _rgb;
    CMVideoFormatDescriptionRef _fmt;
    CGSize _fmtSize;
    OSType _fmtFormat;
    CGSize _outSize;
}

- (instancetype)init {
    if (self = [super init]) {
        _ci = [CIContext contextWithOptions:nil];
        _rgb = CGColorSpaceCreateDeviceRGB();
        _targetPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        _rotationDegrees = 0;
        _mirrored = NO;
        _fillMode = YES;
    }
    return self;
}

- (void)dealloc {
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_fmt) CFRelease(_fmt);
    CGColorSpaceRelease(_rgb);
}

- (CGSize)outputSize { return _outSize; }

- (CMVideoFormatDescriptionRef)formatDescription { return _fmt; }

#pragma mark - 内部

- (void)resetPool {
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
}

- (void)resetFormat {
    if (_fmt) { CFRelease(_fmt); _fmt = NULL; }
}

- (void)ensurePoolForSize:(CGSize)size format:(OSType)format {
    if (_pool && CGSizeEqualToSize(_poolSize, size) && _poolFormat == format) return;
    [self resetPool];
    _poolSize = size;
    _poolFormat = format;
    NSDictionary *props = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        (id)kCVPixelBufferWidthKey:  @((size_t)size.width),
        (id)kCVPixelBufferHeightKey: @((size_t)size.height),
        // 下游可能持有若干帧不立刻归还；给足最小缓冲数，避免池子枯竭导致"出不了帧"。
        // （原版同样设了 kCVPixelBufferPoolMinimumBufferCountKey）
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @(6),
    };
    CVReturn r = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)props, &_pool);
    if (r != kCVReturnSuccess) _pool = NULL;
}

/// 把源图归一化到 (0,0) 起点，再依次做旋转 / 镜像 / 缩放 / 居中
- (CIImage *)transformedImage:(CIImage *)img toSize:(CGSize)dst {
    // 1) 平移到原点，后续变换才好算
    CGRect e = img.extent;
    if (!isfinite(e.origin.x) || !isfinite(e.origin.y) || e.size.width <= 0 || e.size.height <= 0) {
        return nil;
    }
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];

    // 2) 旋转（顺时针）。CGAffineTransform 的旋转在 y 向上的坐标系里是逆时针，
    //    这里用负角度得到顺时针观感，并把旋转后的图像移回原点。
    NSInteger deg = ((self.rotationDegrees % 360) + 360) % 360;
    if (deg != 0) {
        CGFloat rad = -deg * M_PI / 180.0;
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(rad)];
        CGRect r = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-r.origin.x, -r.origin.y)];
    }

    // 3) 水平镜像
    if (self.mirrored) {
        CGRect r = img.extent;
        CGAffineTransform t = CGAffineTransformConcat(
            CGAffineTransformMakeTranslation(r.size.width, 0),
            CGAffineTransformMakeScale(-1, 1));
        img = [img imageByApplyingTransform:t];
        CGRect r2 = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-r2.origin.x, -r2.origin.y)];
    }

    // 4) 缩放到目标尺寸
    CGRect r = img.extent;
    if (r.size.width <= 0 || r.size.height <= 0) return nil;
    CGFloat sx = dst.width / r.size.width;
    CGFloat sy = dst.height / r.size.height;
    CGFloat s = self.fillMode ? MAX(sx, sy) : MIN(sx, sy);
    if (s <= 0 || !isfinite(s)) return nil;
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];

    // 5) 居中（fill 模式会溢出裁切，fit 模式会留边）
    CGRect r2 = img.extent;
    CGFloat tx = (dst.width  - r2.size.width)  / 2.0 - r2.origin.x;
    CGFloat ty = (dst.height - r2.size.height) / 2.0 - r2.origin.y;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    // 6) fit 模式铺一层黑底，避免留边处是脏内存
    if (!self.fillMode) {
        CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]]
                          imageByCroppingToRect:CGRectMake(0, 0, dst.width, dst.height)];
        img = [img imageByCompositingOverImage:black];
    }
    return img;
}

#pragma mark - 转换

- (CVPixelBufferRef)convertBGRA:(CVPixelBufferRef)src {
    if (!src) return NULL;

    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    if (sw == 0 || sh == 0) return NULL;

    NSInteger deg = ((self.rotationDegrees % 360) + 360) % 360;
    BOOL swap = (deg == 90 || deg == 270);
    CGSize dst;
    if (self.targetSize.width > 0 && self.targetSize.height > 0) {
        // 指定了目标尺寸（相机实际尺寸）就按它来，旋转时宽高仍要交换
        dst = swap ? CGSizeMake(self.targetSize.height, self.targetSize.width)
                   : self.targetSize;
    } else {
        dst = swap ? CGSizeMake(sh, sw) : CGSizeMake(sw, sh);
    }

    OSType format = self.targetPixelFormat ?: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    [self ensurePoolForSize:dst format:format];
    if (!_pool) return NULL;

    CVPixelBufferRef out = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &out) != kCVReturnSuccess || !out) {
        return NULL;
    }

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    CIImage *tf = [self transformedImage:img toSize:dst];
    if (!tf) {
        CVPixelBufferRelease(out);
        return NULL;
    }

    @try {
        [_ci render:tf toCVPixelBuffer:out
              bounds:CGRectMake(0, 0, dst.width, dst.height)
          colorSpace:_rgb];
    } @catch (NSException *e) {
        CVPixelBufferRelease(out);
        return NULL;
    }

    // 描述跟随实际输出的 (尺寸, 格式) 重建；不重建就是错配
    if (!_fmt || !CGSizeEqualToSize(_fmtSize, dst) || _fmtFormat != format) {
        [self resetFormat];
        OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, out, &_fmt);
        if (st != noErr) { _fmt = NULL; }
        _fmtSize = dst;
        _fmtFormat = format;
    }
    _outSize = dst;

    return out;   // +1
}

@end
