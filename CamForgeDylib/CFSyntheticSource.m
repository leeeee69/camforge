//
//  CFSyntheticSource.m — 动态渐变 + 移动色块 + 帧号水印
//
//  为什么默认用它：不依赖任何素材文件，装上就能验证 hook 是否生效。
//  帧号是故意烧进画面的——研究时要能一眼看出"这是注入帧"。
//

#import "CFSyntheticSource.h"
#import <CoreGraphics/CoreGraphics.h>

@implementation CFSyntheticSource {
    CVPixelBufferPoolRef _pool;
    size_t _w, _h;
    uint64_t _frameIndex;
    CGColorSpaceRef _rgb;
}

- (instancetype)init {
    if (self = [super init]) {
        _w = 1280; _h = 720;
        _frameIndex = 0;
        _rgb = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    if (_pool) CVPixelBufferPoolRelease(_pool);
    CGColorSpaceRelease(_rgb);
}

- (NSString *)sourceName { return @"合成测试图案"; }
- (CGSize)frameSize { return CGSizeMake(_w, _h); }

- (void)prepare {
    if (_pool) return;
    NSDictionary *props = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey:  @(_w),
        (id)kCVPixelBufferHeightKey: @(_h),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)props, &_pool);
}

- (CVPixelBufferRef)nextPixelBuffer {
    if (!_pool) [self prepare];
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &pb) != kCVReturnSuccess || !pb) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr  = CVPixelBufferGetBytesPerRow(pb);
    CGContextRef ctx = CGBitmapContextCreate(base, _w, _h, 8, bpr, _rgb,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        // 1) 随时间流动的渐变背景
        CGFloat locations[2] = {0.0, 1.0};
        CGFloat t = (CGFloat)(_frameIndex % 180) / 180.0;
        CGFloat comps[8] = {
            0.10 + 0.20 * t, 0.30, 0.60, 1.0,
            0.85, 0.45 - 0.20 * t, 0.25, 1.0,
        };
        CGGradientRef grad = CGGradientCreateWithColorComponents(_rgb, comps, locations, 2);
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(_w, _h), 0);
        CGGradientRelease(grad);

        // 2) 移动色块（一眼看出画面是"活的"）
        CGFloat bx = 120 + 900 * fabs(sin((double)_frameIndex * 0.02));
        CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.9);
        CGContextFillRect(ctx, CGRectMake(bx, 260, 160, 200));

        // 3) 帧号 + 时间戳烧录
        NSString *label = [NSString stringWithFormat:@"CamForge TEST  #%llu  %@",
                           _frameIndex, [NSDate date]];
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont monospacedSystemFontOfSize:28 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: [UIColor whiteColor],
        };
        [label drawAtPoint:CGPointMake(40, 40) withAttributes:attrs];

        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    _frameIndex++;
    return pb;   // +1
}

@end
