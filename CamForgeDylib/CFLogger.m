//
//  CFLogger.m
//

#import "CFLogger.h"
#import <os/lock.h>

static const unsigned long long kCFLogMaxBytes = 2ull * 1024 * 1024;   // 2MB 后截断重来

@implementation CFLogger {
    os_unfair_lock _lock;
    NSUInteger _videoHookHits, _audioHookHits, _injectedFrames, _passthroughFrames;
    NSUInteger _renderedFrames, _sessionsSeen, _directAudioFrames;
    NSMutableArray<NSString *> *_events;

    NSString *_logPath;      ///< 落盘日志绝对路径（nil = 不可写）
    NSFileHandle *_logFH;
}

+ (instancetype)shared {
    static CFLogger *l = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [CFLogger new]; });
    return l;
}

- (instancetype)init {
    if (self = [super init]) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _events = [NSMutableArray array];
        [self setupLogFile];
    }
    return self;
}

/// 建日志文件。位置在宿主 App 沙盒：.../Library/Caches/CamForge/camforge.log
/// 用 Caches 而不是 Documents：不占用户可见存储，也能被 Filza 找到。
/// 崩溃（EXC_BAD_ACCESS 等）时内存事件全丢，但这里已 flush 到文件，事后可查。
- (void)setupLogFile {
    @try {
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (caches.length == 0) return;
        NSString *dir = [caches stringByAppendingPathComponent:@"CamForge"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"camforge.log"];

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size > kCFLogMaxBytes) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        [fh seekToEndOfFile];
        _logFH = fh;
        _logPath = path;
    } @catch (NSException *e) {
        _logFH = nil;
        _logPath = nil;
    }
}

- (NSUInteger)videoHookHits    { os_unfair_lock_lock(&_lock); NSUInteger v = _videoHookHits;    os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)audioHookHits    { os_unfair_lock_lock(&_lock); NSUInteger v = _audioHookHits;    os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)injectedFrames   { os_unfair_lock_lock(&_lock); NSUInteger v = _injectedFrames;   os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)passthroughFrames{ os_unfair_lock_lock(&_lock); NSUInteger v = _passthroughFrames;os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)renderedFrames   { os_unfair_lock_lock(&_lock); NSUInteger v = _renderedFrames;   os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)sessionsSeen     { os_unfair_lock_lock(&_lock); NSUInteger v = _sessionsSeen;     os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)directAudioFrames{ os_unfair_lock_lock(&_lock); NSUInteger v = _directAudioFrames;os_unfair_lock_unlock(&_lock); return v; }

- (void)incVideoHookHit     { os_unfair_lock_lock(&_lock); _videoHookHits++;     os_unfair_lock_unlock(&_lock); }
- (void)incAudioHookHit     { os_unfair_lock_lock(&_lock); _audioHookHits++;     os_unfair_lock_unlock(&_lock); }
- (void)incInjected        { os_unfair_lock_lock(&_lock); _injectedFrames++;    os_unfair_lock_unlock(&_lock); }
- (void)incPassthrough     { os_unfair_lock_lock(&_lock); _passthroughFrames++; os_unfair_lock_unlock(&_lock); }
- (void)incRendered        { os_unfair_lock_lock(&_lock); _renderedFrames++;    os_unfair_lock_unlock(&_lock); }
- (void)incSession         { os_unfair_lock_lock(&_lock); _sessionsSeen++;      os_unfair_lock_unlock(&_lock); }
- (void)incDirectAudio     { os_unfair_lock_lock(&_lock); _directAudioFrames++; os_unfair_lock_unlock(&_lock); }

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[CamForge] %@", s);

    // 落盘（时间戳 + 线程无关），失败静默——日志不能影响主流程
    if (_logFH) {
        @try {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"MM-dd HH:mm:ss.SSS";
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], s];
            NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
            @synchronized (_logFH) {
                [_logFH seekToEndOfFile];
                [_logFH writeData:d];
            }
        } @catch (NSException *e) {
            _logFH = nil;
        }
    }

    os_unfair_lock_lock(&_lock);
    [_events addObject:s];
    if (_events.count > 50) { [_events removeObjectAtIndex:0]; }
    os_unfair_lock_unlock(&_lock);
}

- (NSString *)logFilePath { return _logPath ?: @"(不可写，只能用 syslog)"; }

- (NSString *)tailLines:(NSUInteger)n {
    if (_logPath.length == 0) {
        // 没文件：退回内存流水
        os_unfair_lock_lock(&_lock);
        NSArray *copy = [_events copy];
        os_unfair_lock_unlock(&_lock);
        NSUInteger start = copy.count > n ? copy.count - n : 0;
        return [[copy subarrayWithRange:NSMakeRange(start, copy.count - start)]
                componentsJoinedByString:@"\n"];
    }
    NSData *data = [NSData dataWithContentsOfFile:_logPath];
    if (!data || data.length == 0) return @"(日志文件为空)";
    // 只取尾部 256KB，避免大文件读爆内存
    NSUInteger cap = 256 * 1024;
    if (data.length > cap) {
        data = [data subdataWithRange:NSMakeRange(data.length - cap, cap)];
    }
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [s componentsSeparatedByString:@"\n"];
    NSUInteger start = lines.count > n ? lines.count - n : 0;
    return [[lines subarrayWithRange:NSMakeRange(start, lines.count - start)]
            componentsJoinedByString:@"\n"];
}

- (NSString *)exportTextWithLines:(NSUInteger)n {
    return [NSString stringWithFormat:@"%@\n\n路径：%@\n\n%@",
            [self statsText], [self logFilePath], [self tailLines:n]];
}

- (NSString *)statsText {
    NSArray<NSString *> *tail = nil;
    os_unfair_lock_lock(&_lock);
    NSUInteger n = _events.count;
    NSRange r = NSMakeRange(n > 12 ? n - 12 : 0, n > 12 ? 12 : n);
    tail = [_events subarrayWithRange:r];
    os_unfair_lock_unlock(&_lock);

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"videoHookHits(视频回调命中): %lu\n", (unsigned long)self.videoHookHits];
    [s appendFormat:@"audioHookHits(音频回调命中): %lu\n", (unsigned long)self.audioHookHits];
    [s appendFormat:@"renderedFrames(渲染产出): %lu\n", (unsigned long)self.renderedFrames];
    [s appendFormat:@"injectedFrames(实际注入): %lu\n", (unsigned long)self.injectedFrames];
    [s appendFormat:@"passthroughFrames(透传真帧): %lu\n", (unsigned long)self.passthroughFrames];
    [s appendFormat:@"sessionsSeen(session 数): %lu\n", (unsigned long)self.sessionsSeen];
    [s appendFormat:@"directAudio(推流音频帧): %lu\n", (unsigned long)self.directAudioFrames];
    [s appendString:@"\n最近事件:\n"];
    for (NSString *e in tail) { [s appendFormat:@"• %@\n", e]; }
    return s;
}

@end
