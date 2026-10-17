//
//  CFMovieSource.m — FFmpeg 拉流解码
//
//  管线：avformat_open_input → av_find_best_stream → avcodec（软解）
//        → sws_scale(BGRA) → CVPixelBuffer（+1）
//
//  设计要点：
//   1. 打开/探测全部在 render 队列（首次 nextPixelBuffer）里做 —— RTSP 建连可能
//      阻塞好几秒，绝不能放主线程，否则面板直接卡死。
//   2. RTSP 强制 tcp 传输 + 超时，避免 UDP 丢包导致画面卡住或卡在 open。
//   3. 本地文件 EOF 自动 seek 回 0 循环；网络流 EOF 只报错不重连（重连交给用户点加载）。
//   4. 没有 CF_HAVE_FFMPEG 时整段实现退化为"不可用"，保证工程在无 FFmpeg 环境能编译。
//

#import "CFMovieSource.h"

#if CF_HAVE_FFMPEG

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswscale/swscale.h>
#import <libavutil/imgutils.h>

@implementation CFMovieSource {
    NSString *_urlString;
    BOOL _isFile;

    AVFormatContext *_fmt;
    AVCodecContext *_dec;
    struct SwsContext *_sws;
    AVPacket *_pkt;
    AVFrame *_frame;
    int _streamIndex;
    NSTimeInterval _openTs;
}

+ (BOOL)available { return YES; }

- (instancetype)initWithURLString:(NSString *)urlString isFile:(BOOL)isFile {
    if ((self = [super init])) {
        _urlString = [urlString copy];
        _isFile = isFile;
        _streamIndex = -1;
    }
    return self;
}

- (NSString *)sourceName {
    return _isFile ? (_urlString.lastPathComponent ?: _urlString)
                   : (_urlString ?: @"网络流");
}

- (CGSize)frameSize {
    if (_dec && _dec->width > 0) return CGSizeMake(_dec->width, _dec->height);
    return CGSizeMake(1280, 720);
}

- (void)prepare { /* 真正的 open 放到 render 队列，避免阻塞主线程 */ }

- (void)teardown {
    if (_sws) { sws_freeContext(_sws); _sws = NULL; }
    if (_frame) { av_frame_free(&_frame); }
    if (_pkt) { av_packet_free(&_pkt); }
    if (_dec) { avcodec_free_context(&_dec); }
    if (_fmt) { avformat_close_input(&_fmt); }
    _streamIndex = -1;
}

#pragma mark - 打开

- (BOOL)openInput {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ avformat_network_init(); });

    const char *url = _isFile ? _urlString.fileSystemRepresentation
                              : _urlString.UTF8String;
    if (!url) { self.lastError = @"地址为空"; return NO; }

    AVDictionary *opts = NULL;
    if (!_isFile) {
        // RTSP 默认 UDP，NAT/丢包环境下容易卡住或花屏，强制 TCP 更稳
        av_dict_set(&opts, "rtsp_transport", "tcp", 0);
        av_dict_set(&opts, "timeout", "8000000", 0);        // 8s（微秒）
        av_dict_set(&opts, "stimeout", "8000000", 0);       // 老版本键名
        av_dict_set(&opts, "buffer_size", "2097152", 0);
        av_dict_set(&opts, "reorder_queue_size", "0", 0);
    }

    int r = avformat_open_input(&_fmt, url, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) {
        char buf[128] = {0};
        av_strerror(r, buf, sizeof(buf));
        self.lastError = [NSString stringWithFormat:@"打开失败: %s", buf];
        _fmt = NULL;
        return NO;
    }

    if (avformat_find_stream_info(_fmt, NULL) < 0) {
        self.lastError = @"读取流信息失败";
        avformat_close_input(&_fmt);
        return NO;
    }

    _streamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (_streamIndex < 0) {
        self.lastError = @"流里没有视频轨";
        avformat_close_input(&_fmt);
        return NO;
    }

    AVStream *st = _fmt->streams[_streamIndex];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        self.lastError = [NSString stringWithFormat:@"无解码器 (codec_id=%d)", st->codecpar->codec_id];
        avformat_close_input(&_fmt);
        return NO;
    }

    _dec = avcodec_alloc_context3(codec);
    if (!_dec) { self.lastError = @"分配解码器失败"; return NO; }
    avcodec_parameters_to_context(_dec, st->codecpar);
    _dec->pkt_timebase = st->time_base;
    _dec->thread_count = 0;                 // 自动多线程
    if (avcodec_open2(_dec, codec, NULL) < 0) {
        self.lastError = @"打开解码器失败";
        return NO;
    }

    _pkt = av_packet_alloc();
    _frame = av_frame_alloc();
    if (!_pkt || !_frame) { self.lastError = @"分配帧缓冲失败"; return NO; }

    _openTs = [NSDate date].timeIntervalSince1970;
    self.lastError = nil;
    return YES;
}

- (void)rewind {
    if (!_fmt || _streamIndex < 0) return;
    av_seek_frame(_fmt, _streamIndex, 0, AVSEEK_FLAG_BACKWARD);
    if (_dec) avcodec_flush_buffers(_dec);
}

#pragma mark - 出帧

- (CVPixelBufferRef)pixelBufferFromFrame:(AVFrame *)frame {
    int w = frame->width, h = frame->height;
    if (w <= 0 || h <= 0) return NULL;

    _sws = sws_getCachedContext(_sws, w, h, (enum AVPixelFormat)frame->format,
                                w, h, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
    if (!_sws) return NULL;

    NSDictionary *props = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)props, &pb) != kCVReturnSuccess || !pb) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst[4] = { (uint8_t *)CVPixelBufferGetBaseAddress(pb), NULL, NULL, NULL };
    int dstStride[4] = { (int)CVPixelBufferGetBytesPerRow(pb), 0, 0, 0 };
    sws_scale(_sws, (const uint8_t *const *)frame->data, frame->linesize,
              0, h, dst, dstStride);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    return pb;   // +1
}

- (CVPixelBufferRef)nextPixelBuffer {
    if (!_fmt || !_dec) {
        if (![self openInput]) return NULL;
    }

    for (int guard = 0; guard < 16; guard++) {
        int r = av_read_frame(_fmt, _pkt);
        if (r < 0) {
            if (_isFile) {
                [self rewind];                 // 本地文件循环
                if (av_read_frame(_fmt, _pkt) < 0) return NULL;
            } else {
                self.lastError = @"流已结束或断开（点「加载」重连）";
                return NULL;
            }
        }

        if (_pkt->stream_index != _streamIndex) {
            av_packet_unref(_pkt);
            continue;
        }

        r = avcodec_send_packet(_dec, _pkt);
        av_packet_unref(_pkt);
        if (r < 0 && r != AVERROR(EAGAIN)) continue;

        while (avcodec_receive_frame(_dec, _frame) == 0) {
            CVPixelBufferRef pb = [self pixelBufferFromFrame:_frame];
            av_frame_unref(_frame);
            if (pb) return pb;
        }
    }
    return NULL;
}

@end

#else   // 没有 FFmpeg：退化为"不可用"

@implementation CFMovieSource {
    NSString *_urlString;
    BOOL _isFile;
}

+ (BOOL)available { return NO; }

- (instancetype)initWithURLString:(NSString *)urlString isFile:(BOOL)isFile {
    if ((self = [super init])) {
        _urlString = [urlString copy];
        _isFile = isFile;
        self.lastError = @"本 dylib 未编译 FFmpeg（RTSP/RTMP/FLV 不可用）";
    }
    return self;
}

- (NSString *)sourceName { return _isFile ? @"本地文件(无FFmpeg)" : @"网络流(无FFmpeg)"; }
- (CGSize)frameSize { return CGSizeMake(1280, 720); }
- (void)prepare {}
- (void)teardown {}
- (CVPixelBufferRef)nextPixelBuffer { return NULL; }

@end

#endif
