//
//  CFMovieSource.h — FFmpeg 解码源（RTSP / RTMP / HTTP-FLV / HLS / 本地文件）
//
//  AVFoundation 解不了 RTSP/RTMP/FLV，这几路只能走 FFmpeg。
//  没有编译 FFmpeg 时该类仍然存在（返回 NULL 并给出原因），
//  这样本地/设备端不带 FFmpeg 也能编译过。
//

#import <Foundation/Foundation.h>
#import "CFManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface CFMovieSource : NSObject <CFFrameSource>

/// isFile=YES 时 urlString 是本地绝对路径；NO 时是网络地址
- (instancetype)initWithURLString:(NSString *)urlString isFile:(BOOL)isFile;

/// 是否编译进了 FFmpeg（NO 时该源不可用）
+ (BOOL)available;

/// 最近一次失败原因（打开失败/解码失败/流结束）
@property (nonatomic, copy, nullable) NSString *lastError;

@end

NS_ASSUME_NONNULL_END
