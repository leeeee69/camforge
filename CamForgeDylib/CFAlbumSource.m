//
//  CFAlbumSource.m — 相册最新一条视频作源
//
//  为什么不给选择器：面板是悬浮窗，挂 PHPicker 要跨窗口挂 present，
//  崩的概率比收益大。研究场景"取最新一条"足够验证链路。
//  权限用的是宿主 App（抖音/微信）自身的相册权限；没授权时会提示去系统设置开。
//

#import "CFAlbumSource.h"
#import "CFAssetSource.h"
#import <Photos/Photos.h>

@implementation CFAlbumSource {
    CFAssetSource *_inner;
    BOOL _requested;
    NSString *_state;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = @"相册（未加载）";
    }
    return self;
}

- (NSString *)sourceName { return _inner.sourceName ?: _state; }

- (CGSize)frameSize {
    return _inner ? [_inner frameSize] : CGSizeMake(1280, 720);
}

- (void)prepare { [self loadLatest]; }

- (void)teardown {
    [_inner teardown];
    _inner = nil;
    _requested = NO;
    _state = @"相册（未加载）";
}

- (CVPixelBufferRef)nextPixelBuffer {
    return [_inner nextPixelBuffer];
}

#pragma mark - 读取最新一条

- (void)loadLatest {
    if (_requested) return;
    _requested = YES;

    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (st == PHAuthorizationStatusDenied || st == PHAuthorizationStatusRestricted) {
        _state = @"相册无权限（去系统设置授权宿主 App）";
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (st == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                                   handler:^(PHAuthorizationStatus s) {
            if (s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited) {
                weakSelf->_requested = NO;
                [weakSelf loadLatest];
            } else {
                weakSelf->_state = @"相册授权被拒";
            }
        }];
        _state = @"等待相册授权…";
        return;
    }

    PHFetchOptions *opt = [PHFetchOptions new];
    opt.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
    opt.fetchLimit = 1;
    PHFetchResult<PHAsset *> *res = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeVideo options:opt];
    PHAsset *asset = res.firstObject;
    if (!asset) {
        _state = @"相册里没有视频";
        return;
    }

    _state = @"相册（读取中…）";
    [[PHImageManager defaultManager] requestAVAssetForVideo:asset
                                                    options:nil
                                              resultHandler:^(AVAsset *avAsset, AVAudioMix *audioMix,
                                                              NSDictionary *info) {
        if (!avAsset) {
            weakSelf->_state = @"相册视频读取失败";
            return;
        }
        CFAssetSource *s = [[CFAssetSource alloc] initWithAsset:avAsset];
        weakSelf->_inner = s;
        [s prepare];
        weakSelf->_state = @"相册最新视频";
    }];
}

@end
