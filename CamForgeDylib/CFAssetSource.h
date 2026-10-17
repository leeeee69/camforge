//
//  CFAssetSource.h — AVAssetReader 视频源（本地文件 / 网络 HTTP-HLS 通用）
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import "CFManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface CFAssetSource : NSObject <CFFrameSource>

- (instancetype)initWithURL:(NSURL *)url;

/// 直接用一个已就绪的 AVAsset 作源（相册取到的 asset 走这条）
- (instancetype)initWithAsset:(AVAsset *)asset;

@end

NS_ASSUME_NONNULL_END
