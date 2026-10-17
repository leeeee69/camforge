//
//  CFAssetSource.m — 统一 BGRA 输出 + EOF 循环播放
//
//  说明：AVFoundation 原生不支持 RTSP/RTP。原版工具用 FFmpeg 解 RTSP，
//  这里作为"扩展点"保留（见 README），默认支持 HTTP progressive / HLS。
//
//  2026-10-18 加固：
//   - CMSampleBufferGetImageBuffer 可能返回 NULL（reader 失败/轨道不可解），
//     原代码直接 CVPixelBufferRetain(NULL) 会崩，这里判空。
//   - 连续重建 reader 失败时不再每帧重试（否则 30fps 疯狂创建 AVURLAsset），
//     失败 3 次即停手并记录原因。
//

#import "CFAssetSource.h"

@interface CFAssetSource ()
- (BOOL)restartReader;
@end

@implementation CFAssetSource {
    NSURL *_url;
    AVURLAsset *_asset;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_trackOut;
    NSInteger _restartFailures;
}

- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [super init])) {
        _url = url;
        _restartFailures = 0;
    }
    return self;
}

- (NSString *)sourceName {
    return _url.lastPathComponent.length ? _url.lastPathComponent : (_url.absoluteString ?: @"");
}

- (CGSize)frameSize {
    AVAssetTrack *t = [[[AVURLAsset URLAssetWithURL:_url options:nil]
                        tracksWithMediaType:AVMediaTypeVideo] firstObject];
    return t ? t.naturalSize : CGSizeMake(1280, 720);
}

- (void)prepare { [self restartReader]; }

- (void)teardown {
    _reader = nil;
    _trackOut = nil;
    _asset = nil;
}

- (BOOL)restartReader {
    if (_restartFailures >= 3) return NO;

    _reader = nil;
    _trackOut = nil;
    _asset = [AVURLAsset URLAssetWithURL:_url options:nil];
    if (!_asset) { _restartFailures++; return NO; }

    AVAssetTrack *track = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        // 远程资产首次访问时轨道表可能还没加载完；记一次失败，下一帧再试
        _restartFailures++;
        return NO;
    }

    NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
    _trackOut = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                          outputSettings:settings];
    _trackOut.alwaysCopiesSampleData = NO;

    NSError *err = nil;
    _reader = [AVAssetReader assetReaderWithAsset:_asset error:&err];
    if (!_reader) {
        _restartFailures++;
        return NO;
    }
    if (![_reader canAddOutput:_trackOut]) {
        _restartFailures++;
        return NO;
    }
    [_reader addOutput:_trackOut];
    if (![_reader startReading]) {
        _restartFailures++;
        return NO;
    }
    _restartFailures = 0;
    return YES;
}

- (CVPixelBufferRef)nextPixelBuffer {
    if (!_reader && ![self restartReader]) return NULL;

    CMSampleBufferRef sb = [_trackOut copyNextSampleBuffer];
    if (!sb) {
        // EOF 或读取中断 → 重建一次循环播放
        if (![self restartReader]) return NULL;
        sb = [_trackOut copyNextSampleBuffer];
        if (!sb) return NULL;
    }

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) {                       // 图像缓冲为空：直接丢弃该帧，别往下 retain NULL
        CFRelease(sb);
        return NULL;
    }
    CVPixelBufferRetain(pb);
    CFRelease(sb);
    return pb;   // +1（调用方负责释放）
}

@end
