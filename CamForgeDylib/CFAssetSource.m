//
//  CFAssetSource.m — 统一 BGRA 输出 + EOF 循环播放
//
//  说明：AVFoundation 原生不支持 RTSP/RTP。原版工具用 FFmpeg 解 RTSP，
//  这里作为"扩展点"保留（见 README），默认支持 HTTP progressive / HLS。
//

#import "CFAssetSource.h"

@implementation CFAssetSource {
    NSURL *_url;
    AVURLAsset *_asset;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_trackOut;
}

- (instancetype)initWithURL:(NSURL *)url {
    if (self = [super init]) {
        _url = url;
    }
    return self;
}

- (NSString *)sourceName {
    return _url.lastPathComponent.length ? _url.lastPathComponent : _url.absoluteString;
}

- (CGSize)frameSize {
    _asset = [AVURLAsset URLAssetWithURL:_url options:nil];
    AVAssetTrack *t = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    return t ? t.naturalSize : CGSizeMake(1280, 720);
}

- (void)prepare { [self restartReader]; }

- (void)teardown {
    _reader = nil;
    _trackOut = nil;
    _asset = nil;
}

- (void)restartReader {
    _asset = [AVURLAsset URLAssetWithURL:_url options:nil];
    AVAssetTrack *track = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) { _reader = nil; _trackOut = nil; return; }
    NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
    _trackOut = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                          outputSettings:settings];
    _trackOut.alwaysCopiesSampleData = NO;
    _reader = [AVAssetReader assetReaderWithAsset:_asset error:NULL];
    [_reader addOutput:_trackOut];
    [_reader startReading];
}

- (CVPixelBufferRef)nextPixelBuffer {
    if (!_reader) [self restartReader];
    if (!_trackOut) return NULL;

    CMSampleBufferRef sb = [_trackOut copyNextSampleBuffer];
    if (!sb) {
        [self restartReader];            // EOF → 循环播放
        sb = [_trackOut copyNextSampleBuffer];
        if (!sb) return NULL;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    CVPixelBufferRetain(pb);
    CFRelease(sb);
    return pb;   // +1（下一次 copyNext 前必须已被消费，见 CFManager）
}

@end
