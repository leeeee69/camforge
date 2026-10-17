//
//  CFExternalSource.m — 外部摄像头（USB-C UVC）直通
//
//  用自己的一条 AVCaptureSession 抓外接摄像头，BGRA 出帧，供注入管线当源。
//  ⚠️ 宿主 App 同时占用摄像头时 iOS 可能拒绝第二路会话（表现是一直没有帧），
//  这不是崩溃，面板会显示「等待外部摄像头帧」。
//

#import "CFExternalSource.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

@interface CFExternalSource () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation CFExternalSource {
    AVCaptureSession *_session;
    AVCaptureVideoDataOutput *_output;
    CVPixelBufferRef _latest;
    os_unfair_lock _lock;
    NSString *_state;
    NSUInteger _frameCount;
}

+ (BOOL)supported {
    if (@available(iOS 17.0, *)) return YES;
    return NO;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _state = @"USB（未连接）";
    }
    return self;
}

- (void)dealloc {
    [self teardown];
}

- (NSString *)sourceName { return _state; }

- (CGSize)frameSize {
    if (_latest) return CGSizeMake(CVPixelBufferGetWidth(_latest), CVPixelBufferGetHeight(_latest));
    return CGSizeMake(1280, 720);
}

- (void)prepare {
    if (_session) return;
    if (![CFExternalSource supported]) {
        _state = @"USB 直通需 iOS 17+";
        return;
    }
    if (@available(iOS 17.0, *)) {
        AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                                  mediaType:AVMediaTypeVideo
                                   position:AVCaptureDevicePositionUnspecified];
        AVCaptureDevice *dev = ds.devices.firstObject;
        if (!dev) {
            _state = @"未检测到外部摄像头";
            return;
        }

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        if (!input) {
            _state = [NSString stringWithFormat:@"外部摄像头打不开: %@",
                      err.localizedDescription ?: @"unknown"];
            return;
        }

        AVCaptureSession *s = [AVCaptureSession new];
        if ([s canAddInput:input]) [s addInput:input];

        AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
        out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        out.alwaysDiscardsLateVideoFrames = YES;
        dispatch_queue_t q = dispatch_queue_create("com.camforge.external", DISPATCH_QUEUE_SERIAL);
        [out setSampleBufferDelegate:self queue:q];
        if ([s canAddOutput:out]) [s addOutput:out];

        _output = out;
        _session = s;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [s startRunning];
        });
        _state = [NSString stringWithFormat:@"USB: %@",
                  dev.localizedName ?: @"外部摄像头"];
    }
}

- (void)teardown {
    if (_session) {
        AVCaptureSession *s = _session;
        _session = nil;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [s stopRunning];
        });
    }
    _output = nil;

    os_unfair_lock_lock(&_lock);
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - 回调

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;
    CVPixelBufferRetain(pb);

    os_unfair_lock_lock(&_lock);
    if (_latest) CVPixelBufferRelease(_latest);
    _latest = pb;
    _frameCount++;
    BOOL first = (_frameCount == 1);
    os_unfair_lock_unlock(&_lock);

    if (first) _state = @"USB: 已出帧";
}

- (CVPixelBufferRef)nextPixelBuffer {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef pb = _latest;
    if (pb) CVPixelBufferRetain(pb);
    os_unfair_lock_unlock(&_lock);
    return pb;   // +1 或 NULL
}

@end
