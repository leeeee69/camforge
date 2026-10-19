//
//  CFStreamPreview.m
//

#import "CFStreamPreview.h"
#import "CFMovieSource.h"
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <os/lock.h>

@interface CFStreamPreview ()
@property (nonatomic, strong, nullable) CFMovieSource *source;
@property (nonatomic, strong, nullable) dispatch_source_t timer;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy, nullable) UIImage *image;
@property (nonatomic, assign) BOOL frameOK;
@end

@implementation CFStreamPreview {
    os_unfair_lock _lock;
    NSUInteger _pulled;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _previewFPS = 10;
        _status = @"连接中…";
    }
    return self;
}

- (void)dealloc { [self stop]; }

#pragma mark - 属性（加锁，跨预览队列与主线程）

- (NSString *)statusText {
    os_unfair_lock_lock(&_lock);
    NSString *s = _status;
    os_unfair_lock_unlock(&_lock);
    return s;
}

- (UIImage *)latestImage {
    os_unfair_lock_lock(&_lock);
    UIImage *i = _image;
    os_unfair_lock_unlock(&_lock);
    return i;
}

- (BOOL)hasFrame {
    os_unfair_lock_lock(&_lock);
    BOOL b = _frameOK;
    os_unfair_lock_unlock(&_lock);
    return b;
}

- (void)setStatusText:(NSString *)s {
    os_unfair_lock_lock(&_lock);
    _status = [s copy];
    os_unfair_lock_unlock(&_lock);
}

- (void)setLatestImage:(UIImage *)img {
    os_unfair_lock_lock(&_lock);
    _image = img;
    _frameOK = YES;
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - 生命周期

- (void)startWithURL:(NSString *)url isFile:(BOOL)isFile {
    [self stop];
    self.source = [[CFMovieSource alloc] initWithURLString:url isFile:isFile];
    [self setStatusText:@"连接中…"];

    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.camforge.preview", DISPATCH_QUEUE_SERIAL);
    });

    uint64_t interval = (uint64_t)(1.0 / MAX(self.previewFPS, 1) * NSEC_PER_SEC);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, interval, 1 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        [weakSelf pullOneFrame];
    });
    dispatch_resume(t);
    self.timer = t;
}

- (void)stop {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    self.source = nil;
    os_unfair_lock_lock(&_lock);
    _image = nil;
    _frameOK = NO;
    os_unfair_lock_unlock(&_lock);
}

- (void)pullOneFrame {
    CFMovieSource *src = self.source;
    if (!src) return;

    CVPixelBufferRef pb = [src nextPixelBuffer];
    if (!pb) {
        // 连续拉不到帧：把源的失败原因透出来
        if (src.lastError.length) {
            [self setStatusText:src.lastError];
        } else if (self.hasFrame) {
            [self setStatusText:@"流中断，等待恢复…"];
        } else {
            [self setStatusText:@"等待首帧…"];
        }
        return;
    }

    UIImage *img = [CFStreamPreview imageFromPixelBuffer:pb];
    CVPixelBufferRelease(pb);
    if (!img) return;

    _pulled++;
    [self setLatestImage:img];
    [self setStatusText:[NSString stringWithFormat:@"已出帧 %lu", (unsigned long)_pulled]];
}

#pragma mark - CVPixelBuffer → UIImage

+ (UIImage *)imageFromPixelBuffer:(CVPixelBufferRef)pb {
    if (!pb) return nil;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    if (w == 0 || h == 0) return nil;

    // 源统一出 BGRA，直接按 BGRA 包成 CGImage
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    UIImage *img = nil;
    if (cg) {
        img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
        CGImageRelease(cg);
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return img;
}

@end
