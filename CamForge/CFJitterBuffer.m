//
//  CFJitterBuffer.m
//
//  设计取舍：原版工具用"lead frames + 丢帧策略 + 缓刑探测"那套重逻辑。
//  自研版用 4 帧环形缓冲 + 满则丢旧，等价解决"源速率 ≠ 相机速率"的抖动问题，
//  代码量从不可读降到 60 行。研究场景够用。
//

#import "CFJitterBuffer.h"
#import <os/lock.h>

@implementation CFJitterBuffer {
    CMSampleBufferRef _slots[4];
    os_unfair_lock _lock;
}

- (instancetype)init {
    if (self = [super init]) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc { [self drain]; }

- (void)pushSampleBuffer:(CMSampleBufferRef)sb {
    os_unfair_lock_lock(&_lock);
    if (_slots[3]) CFRelease(_slots[3]);          // 丢最旧
    for (int i = 3; i > 0; i--) _slots[i] = _slots[i - 1];
    _slots[0] = (CMSampleBufferRef)CFRetain(sb);  // 最新在 [0]
    os_unfair_lock_unlock(&_lock);
}

- (CMSampleBufferRef)popRetained {
    os_unfair_lock_lock(&_lock);
    CMSampleBufferRef sb = _slots[0];
    for (int i = 0; i < 3; i++) _slots[i] = _slots[i + 1];
    _slots[3] = NULL;
    if (sb) CFRetain(sb);
    os_unfair_lock_unlock(&_lock);
    return sb;
}

- (void)drain {
    os_unfair_lock_lock(&_lock);
    for (int i = 0; i < 4; i++) {
        if (_slots[i]) { CFRelease(_slots[i]); _slots[i] = NULL; }
    }
    os_unfair_lock_unlock(&_lock);
}

@end
