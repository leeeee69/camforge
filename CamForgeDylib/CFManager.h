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
    CFSourceTypeDirect,         ///< 直连：相机原样透传，不注入（A/B 对照）
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
@property (nonatomic, assign) CGSize outputSize;          ///< 最近一帧输出分辨率
@property (nonatomic, readonly) CFPixelConverter *converter;
@property (nonatomic, readonly) CFJitterBuffer *jitter;
@property (nonatomic, assign) CFSourceType sourceType;    ///< 当前源类型（直连=不注入）

#pragma mark - 渲染选项（UI 上那几个开关）

@property (nonatomic, assign) OSType targetPixelFormat;   ///< 跟随目标 output.videoSettings
@property (nonatomic, assign) NSInteger rotationDegrees;  ///< 0/90/180/270
@property (nonatomic, assign) BOOL mirrored;              ///< 画面镜像
@property (nonatomic, assign) BOOL fillMode;              ///< YES 填充 / NO 适应
@property (nonatomic, assign) BOOL frameDedupe;           ///< 画面去重
@property (nonatomic, assign) BOOL audioDedupe;           ///< 音频去重
@property (nonatomic, assign) CGFloat panelAlpha;         ///< 面板透明度（0.5~1.0）

@property (nonatomic, copy, nullable) NSString *lastError;///< 最近一次失败原因（面板展示）

+ (instancetype)shared;

- (void)startReplacing;
- (void)stopReplacing;
- (void)switchToSourceType:(CFSourceType)type urlOrPath:(nullable NSString *)s;

/// 目标 App 给 output 配的 videoSettings —— 必须按它出帧，否则下游解析会崩
- (void)noteVideoOutputSettings:(nullable NSDictionary *)settings;

/// 把 manager 上的选项同步到转换器
- (void)syncRenderOptions;

/// 供 CFCaptureProxy 取帧：最新假视频帧（+1，调用方 CFRelease）
- (nullable CMSampleBufferRef)nextVideoSampleBuffer;
/// 音频注入关时原样透传 original；开启时返回 440Hz 正弦标记音（+1）
- (nullable CMSampleBufferRef)nextAudioSampleBufferMatching:(CMSampleBufferRef)original;

/// 对已运行的 session 补挂 hook（防止 App 在插件加载前就设好了 delegate）
- (void)rescanSessionOutputs:(AVCaptureSession *)session;

- (void)showMenu;

@end

NS_ASSUME_NONNULL_END
