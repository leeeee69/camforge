//
//  CFDirectSource.m — 直连源实现（TCP + JPEG 逐帧）
//
//  为什么用 JPEG 而不是 H.264：H.264 要对齐参数集（SPS/PPS）、时间戳、解码器
//  重配置，PC 端也得走编码器；研究场景下 JPEG 足够——720p 每帧 ~80-150KB，
//  30fps 约 3-4MB/s，usbmuxd 完全吃得下，两端实现都短。
//

#import "CFDirectSource.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <os/lock.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

static const uint32_t kCFMagic = 0x4D524643;   // "CFRM" little-endian
static const uint8_t  kCFVersion = 0x01;
static const uint8_t  kCFTypeJPEG = 0x01;
static const uint8_t  kCFTypePCM  = 0x02;
static const NSUInteger kCFAudioRate = 44100;
static const NSUInteger kCFAudioCh   = 2;
static const NSUInteger kCFAudioMaxBytes = kCFAudioRate * kCFAudioCh * 2;   // 缓冲 1 秒
static const uint32_t kCFMaxPayload = 8u * 1024u * 1024u;   // 8MB 上限，防脏数据撑爆内存

static BOOL cf_read_full(int fd, void *buf, size_t len) {
    size_t got = 0;
    uint8_t *p = (uint8_t *)buf;
    while (got < len) {
        ssize_t n = read(fd, p + got, len - got);
        if (n <= 0) return NO;
        got += (size_t)n;
    }
    return YES;
}

@implementation CFDirectSource {
    uint16_t _port;
    int _listenFD;
    int _clientFD;
    CVPixelBufferRef _latest;
    os_unfair_lock _lock;
    NSString *_state;
    NSUInteger _frames;
    BOOL _running;
    CGColorSpaceRef _rgb;

    NSMutableData *_audioBuf;
    os_unfair_lock _audioLock;
    BOOL _gotAudio;

    os_unfair_lock _stateLock;   ///< _state 会被收发线程写、主线程（面板）读，必须加锁
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _port = port ?: 9527;
        _listenFD = -1;
        _clientFD = -1;
        _lock = OS_UNFAIR_LOCK_INIT;
        _audioLock = OS_UNFAIR_LOCK_INIT;
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _audioBuf = [NSMutableData dataWithCapacity:kCFAudioMaxBytes];
        [self setStateText:[NSString stringWithFormat:@"直连: 等待 PC 连接 (端口 %u)", _port]];
        _rgb = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_rgb) CGColorSpaceRelease(_rgb);
}

- (uint16_t)port { return _port; }

- (void)setStateText:(NSString *)text {
    os_unfair_lock_lock(&_stateLock);
    _state = [text copy];
    os_unfair_lock_unlock(&_stateLock);
}

- (NSString *)sourceName {
    os_unfair_lock_lock(&_stateLock);
    NSString *s = _state;
    os_unfair_lock_unlock(&_stateLock);
    return s;
}

- (CGSize)frameSize {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef pb = _latest;
    CGSize s = pb ? CGSizeMake(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
                  : CGSizeMake(1280, 720);
    os_unfair_lock_unlock(&_lock);
    return s;
}

#pragma mark - 生命周期

- (void)prepare { [self start]; }

- (void)teardown { [self stop]; }

- (void)start {
    if (_running) return;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { [self setStateText:@"直连: socket 创建失败"]; return; }

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // 只监听回环，usbmuxd 转发进来

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int e = errno;
        close(fd);
        [self setStateText:[NSString stringWithFormat:@"直连: 端口 %u 被占用 (errno %d)", _port, e]];
        return;
    }
    if (listen(fd, 1) < 0) {
        close(fd);
        [self setStateText:@"直连: listen 失败"];
        return;
    }

    _listenFD = fd;
    _running = YES;
    [self setStateText:[NSString stringWithFormat:@"直连: 已监听 %u，等 PC 推送", _port]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        [self_ acceptLoop];
    });
}

- (void)stop {
    _running = NO;
    if (_clientFD >= 0) { close(_clientFD); _clientFD = -1; }
    if (_listenFD >= 0) { close(_listenFD); _listenFD = -1; }

    os_unfair_lock_lock(&_lock);
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    os_unfair_lock_unlock(&_lock);

    os_unfair_lock_lock(&_audioLock);
    [_audioBuf setLength:0];
    _gotAudio = NO;
    os_unfair_lock_unlock(&_audioLock);
}

- (void)acceptLoop {
    while (_running && _listenFD >= 0) {
        int c = accept(_listenFD, NULL, NULL);
        if (c < 0) break;

        // 收包超时，方便 teardown 时退出阻塞 read
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        int on = 1;
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

        _clientFD = c;
        _frames = 0;
        [self setStateText:[NSString stringWithFormat:@"直连: PC 已连接 (%u)", _port]];

        [self readLoop:c];

        close(c);
        _clientFD = -1;
        [self setStateText:[NSString stringWithFormat:@"直连: 已断开，等重连 (%u)", _port]];
    }
}

- (void)readLoop:(int)fd {
    while (_running) {
        uint8_t hdr[12];
        if (!cf_read_full(fd, hdr, sizeof(hdr))) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) { if (!_running) return; continue; }
            return;
        }

        uint32_t magic = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8) |
                         ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
        uint8_t version = hdr[4];
        uint8_t type = hdr[5];
        uint32_t len = (uint32_t)hdr[8] | ((uint32_t)hdr[9] << 8) |
                       ((uint32_t)hdr[10] << 16) | ((uint32_t)hdr[11] << 24);

        if (magic != kCFMagic || version != kCFVersion) {
            [self setStateText:@"直连: 协议头不匹配（magic/version）"];
            return;
        }
        if (len == 0 || len > kCFMaxPayload) {
            [self setStateText:[NSString stringWithFormat:@"直连: 负载长度异常 %u", len]];
            return;
        }

        NSMutableData *payload = [NSMutableData dataWithLength:len];
        if (!cf_read_full(fd, payload.mutableBytes, len)) return;

        if (type == kCFTypePCM) {
            [self appendAudio:payload];
        } else if (type == kCFTypeJPEG) {
            CVPixelBufferRef pb = [self pixelBufferFromJPEG:payload];
            if (pb) {
                os_unfair_lock_lock(&_lock);
                if (_latest) CVPixelBufferRelease(_latest);
                _latest = pb;
                _frames++;
                NSUInteger n = _frames;
                os_unfair_lock_unlock(&_lock);
                if (n == 1) [self setStateText:[NSString stringWithFormat:@"直连: 已出帧 (%u)", _port]];
            }
        }
        // 其他 type 先忽略（预留音频/控制）
    }
}

#pragma mark - JPEG → CVPixelBuffer

- (CVPixelBufferRef)pixelBufferFromJPEG:(NSData *)data {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;

    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (w == 0 || h == 0) { CGImageRelease(img); return NULL; }

    NSDictionary *props = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)props, &pb);
    if (r != kCVReturnSuccess || !pb) { CGImageRelease(img); return NULL; }

    CVPixelBufferLockBaseAddress(pb, 0);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8,
                                             CVPixelBufferGetBytesPerRow(pb), _rgb,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(img);
    return pb;   // +1
}

#pragma mark - 音频

+ (NSUInteger)audioSampleRate { return kCFAudioRate; }
+ (NSUInteger)audioChannels { return kCFAudioCh; }

- (BOOL)hasAudio {
    os_unfair_lock_lock(&_audioLock);
    BOOL has = _gotAudio;
    os_unfair_lock_unlock(&_audioLock);
    return has;
}

- (void)appendAudio:(NSData *)pcm {
    if (pcm.length == 0) return;
    os_unfair_lock_lock(&_audioLock);
    [_audioBuf appendData:pcm];
    if (_audioBuf.length > kCFAudioMaxBytes) {          // 只保留最近 1 秒，防 PC 推太快
        NSUInteger drop = _audioBuf.length - kCFAudioMaxBytes;
        [_audioBuf replaceBytesInRange:NSMakeRange(0, drop) withBytes:NULL length:0];
    }
    _gotAudio = YES;
    os_unfair_lock_unlock(&_audioLock);
}

- (NSData *)takeAudioBytes:(NSUInteger)bytes {
    if (bytes == 0) return nil;
    os_unfair_lock_lock(&_audioLock);
    NSData *out = nil;
    if (_audioBuf.length >= bytes) {
        out = [_audioBuf subdataWithRange:NSMakeRange(0, bytes)];
        [_audioBuf replaceBytesInRange:NSMakeRange(0, bytes) withBytes:NULL length:0];
    } else if (_audioBuf.length > 0) {
        // 不够就让下游拿短的（会补静音），总比卡住强
        out = [_audioBuf copy];
        [_audioBuf setLength:0];
    }
    os_unfair_lock_unlock(&_audioLock);
    return out;
}

#pragma mark - 出帧

- (CVPixelBufferRef)nextPixelBuffer {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef pb = _latest;
    if (pb) CVPixelBufferRetain(pb);
    os_unfair_lock_unlock(&_lock);
    return pb;
}

@end
