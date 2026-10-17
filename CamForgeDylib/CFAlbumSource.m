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

@interface CFAlbumSource ()
@property (nonatomic, strong, nullable) CFAssetSource *inner;
@property (nonatomic, copy) NSString *state;
@property (nonatomic, assign) BOOL requested;
@end

@implementation CFAlbumSource

- (instancetype)init {
    if ((self = [super init])) {
        _state = @"相册（未加载）";
    }
    return self;
}

- (NSString *)sourceName { return self.inner.sourceName ?: self.state; }

- (CGSize)frameSize {
    return self.inner ? [self.inner frameSize] : CGSizeMake(1280, 720);
}

- (void)prepare { [self loadLatest]; }

- (void)teardown {
    [self.inner teardown];
    self.inner = nil;
    self.requested = NO;
    self.state = @"相册（未加载）";
}

- (CVPixelBufferRef)nextPixelBuffer {
    return [self.inner nextPixelBuffer];
}

#pragma mark - 读取最新一条

- (void)loadLatest {
    if (self.requested) return;
    self.requested = YES;

    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (st == PHAuthorizationStatusDenied || st == PHAuthorizationStatusRestricted) {
        self.state = @"相册无权限（去系统设置授权宿主 App）";
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (st == PHAuthorizationStatusNotDetermined) {
        self.state = @"等待相册授权…";
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                                   handler:^(PHAuthorizationStatus s) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            if (s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited) {
                self_.requested = NO;
                [self_ loadLatest];
            } else {
                self_.state = @"相册授权被拒";
            }
        }];
        return;
    }

    PHFetchOptions *opt = [PHFetchOptions new];
    opt.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
    opt.fetchLimit = 1;
    PHFetchResult<PHAsset *> *res = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeVideo options:opt];
    PHAsset *asset = res.firstObject;
    if (!asset) {
        self.state = @"相册里没有视频";
        return;
    }

    self.state = @"相册（读取中…）";
    [[PHImageManager defaultManager] requestAVAssetForVideo:asset
                                                    options:nil
                                              resultHandler:^(AVAsset *avAsset, AVAudioMix *audioMix,
                                                              NSDictionary *info) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        if (!avAsset) {
            self_.state = @"相册视频读取失败";
            return;
        }
        CFAssetSource *s = [[CFAssetSource alloc] initWithAsset:avAsset];
        self_.inner = s;
        [s prepare];
        self_.state = @"相册最新视频";
    }];
}

@end
