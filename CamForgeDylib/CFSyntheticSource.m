//
//  CFSyntheticSource.m — 动态渐变 + 移动色块 + 帧号水印
//
//  为什么默认用它：不依赖任何素材文件，装上就能验证 hook 是否生效。
//  帧号是故意烧进画面的——研究时要能一眼看出"这是注入帧"。
//
//  ⚠️ 崩溃修复（2026-10-18）：这里原先用 -[NSString drawAtPoint:withAttributes:]
//  画文字。那套 API 依赖线程局部的 UIGraphics 上下文，而本函数跑在
//  com.camforge.render 后台队列上，没有任何 UIGraphics 上下文 —— 一点"开始替换"
//  就抛异常崩溃。现在改用 CoreText（CTLineDraw）直接画进 CGContext，任意线程安全。
//

#import "CFSyntheticSource.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <math.h>

/// 在 CGContext 里用 CoreText 画一行字（任意线程可用，无 UIKit 上下文依赖）
static void cf_draw_line(CGContextRef ctx, NSString *text, CGFloat x, CGFloat y,
                         CGFloat size, CGColorRef color, bool monospaced) {
    if (!ctx || text.length == 0) return;

    CFStringRef fontName = monospaced ? CFSTR("Courier") : CFSTR("Helvetica");
    CTFontRef font = CTFontCreateWithName(fontName, size, NULL);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color,
    };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    if (line) {
        CGContextSaveGState(ctx);
        // CoreGraphics 文本坐标是「y 向上 + 基线起点」，这里显式归位避免继承脏状态
        CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
        CGContextSetTextPosition(ctx, x, y);
        CTLineDraw(line, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(line);
    }
    if (font) CFRelease(font);
}

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

- (void)teardown {
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
}

- (CVPixelBufferRef)nextPixelBuffer {
    if (!_pool) [self prepare];
    if (!_pool) return NULL;

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
        if (grad) {
            CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(_w, _h), 0);
            CGGradientRelease(grad);
        }

        // 2) 移动色块（一眼看出画面是"活的"）
        CGFloat bx = 120 + 900 * fabs(sin((double)_frameIndex * 0.02));
        CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.9);
        CGContextFillRect(ctx, CGRectMake(bx, _h * 0.35, 160, 200));

        // 3) 帧号 + 时间戳烧录（CoreText，坐标 y 向上，所以从顶部算要减去高度）
        CGColorRef white = CGColorCreate(_rgb, (CGFloat[]){1, 1, 1, 1});
        NSString *title = @"CamForge TEST";
        NSString *detail = [NSString stringWithFormat:@"frame #%llu   %@",
                            _frameIndex, [NSDate date]];
        cf_draw_line(ctx, title, 40, _h - 70, 46, white, false);
        cf_draw_line(ctx, detail, 40, _h - 110, 26, white, true);
        CGColorRelease(white);

        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    _frameIndex++;
    return pb;   // +1
}

@end
