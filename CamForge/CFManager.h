//
//  CamForge — 自研虚拟相机研究插件（clean-room，无授权模块）
//  CFManager.h
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CFPixelConverter, CFJitterBuffer;

typedef NS_ENUM(NSInteger, CFSourceType) {
    CFSourceTypeSynthetic = 0,  ///< 内置合成测试图案（默认，零依赖）
    CFSourceTypeVideoFile,      ///< 本地视频文件（AVAssetReader 循环播放）
    CFSourceTypeNetwork,        ///< 网络流 HTTP/HLS（AVURLAsset）
};

/// 帧源协议：所有源统一输出 BGRA CVPixelBuffer（返回 +1，调用方负责释放）
@protocol CFFrameSource <NSObject>
@required
- (nullable CVPixelBufferRef)nextPixelBuffer;
- (CGSize)frameSize;
- (NSString *)sourceName;
@optional
- (void)prepare;
- (void)teardown;
@end

@interface CFManager : NSObject

@property (nonatomic, assign) BOOL replacing;             ///< 是否正在向相机链路注入假帧
@property (nonatomic, assign) BOOL audioReplaceEnabled;   ///< 音频注入开关（默认关）
@property (nonatomic, strong, nullable) id<CFFrameSource> source;
@property (nonatomic, assign) CGSize outputSize;          ///< 输出分辨率，默认 1280x720
@property (nonatomic, readonly) CFPixelConverter *converter;
@property (nonatomic, readonly) CFJitterBuffer *jitter;

+ (instancetype)shared;

- (void)startReplacing;
- (void)stopReplacing;
- (void)switchToSourceType:(CFSourceType)type urlOrPath:(nullable NSString *)s;

/// 供 CFCaptureProxy 取帧：最新假视频帧（+1，调用方 CFRelease）
- (nullable CMSampleBufferRef)nextVideoSampleBuffer;
/// 音频注入关时原样透传 original；开启时返回 440Hz 正弦标记音（+1）
- (nullable CMSampleBufferRef)nextAudioSampleBufferMatching:(CMSampleBufferRef)original;

/// 对已运行的 session 补挂 hook（防止 App 在插件加载前就设好了 delegate）
- (void)rescanSessionOutputs:(AVCaptureSession *)session;

- (void)showMenu;

@end

NS_ASSUME_NONNULL_END
