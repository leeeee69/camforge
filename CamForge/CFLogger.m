//
//  CFLogger.m
//

#import "CFLogger.h"
#import <os/lock.h>

@implementation CFLogger {
    os_unfair_lock _lock;
    NSUInteger _videoHookHits, _audioHookHits, _injectedFrames, _passthroughFrames;
    NSUInteger _renderedFrames, _sessionsSeen;
    NSMutableArray<NSString *> *_events;
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
    }
    return self;
}

- (NSUInteger)videoHookHits    { os_unfair_lock_lock(&_lock); NSUInteger v = _videoHookHits;    os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)audioHookHits    { os_unfair_lock_lock(&_lock); NSUInteger v = _audioHookHits;    os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)injectedFrames   { os_unfair_lock_lock(&_lock); NSUInteger v = _injectedFrames;   os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)passthroughFrames{ os_unfair_lock_lock(&_lock); NSUInteger v = _passthroughFrames;os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)renderedFrames   { os_unfair_lock_lock(&_lock); NSUInteger v = _renderedFrames;   os_unfair_lock_unlock(&_lock); return v; }
- (NSUInteger)sessionsSeen     { os_unfair_lock_lock(&_lock); NSUInteger v = _sessionsSeen;     os_unfair_lock_unlock(&_lock); return v; }

- (void)incVideoHookHit     { os_unfair_lock_lock(&_lock); _videoHookHits++;     os_unfair_lock_unlock(&_lock); }
- (void)incAudioHookHit     { os_unfair_lock_lock(&_lock); _audioHookHits++;     os_unfair_lock_unlock(&_lock); }
- (void)incInjected        { os_unfair_lock_lock(&_lock); _injectedFrames++;    os_unfair_lock_unlock(&_lock); }
- (void)incPassthrough     { os_unfair_lock_lock(&_lock); _passthroughFrames++; os_unfair_lock_unlock(&_lock); }
- (void)incRendered        { os_unfair_lock_lock(&_lock); _renderedFrames++;    os_unfair_lock_unlock(&_lock); }
- (void)incSession         { os_unfair_lock_lock(&_lock); _sessionsSeen++;      os_unfair_lock_unlock(&_lock); }

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[CamForge] %@", s);
    os_unfair_lock_lock(&_lock);
    [_events addObject:s];
    if (_events.count > 50) { [_events removeObjectAtIndex:0]; }
    os_unfair_lock_unlock(&_lock);
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
    [s appendString:@"\n最近事件:\n"];
    for (NSString *e in tail) { [s appendFormat:@"• %@\n", e]; }
    return s;
}

@end
