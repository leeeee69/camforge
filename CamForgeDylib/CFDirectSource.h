//
//  CFDirectSource.h — 直连源：PC 经 usbmuxd 把视音频推给手机（"USB 直连"）
//
//  机制（与原版同一套传输，协议是我们自己定的）：
//    手机侧监听 127.0.0.1:<port>
//    PC 侧  iproxy <port> <port>  →  跑 tools/cf-push.py 推帧
//
//  帧格式（全部小端，header 12B）：
//    magic  4B  "CFRM"
//    version1B  0x01
//    type   1B  0x01 = JPEG 视频整帧
//               0x02 = PCM 音频（s16le 交错，44100Hz / 2ch / 每包 20ms = 1764B）
//    resv   2B  0
//    length 4B  负载字节数
//    payload    JPEG 数据 或 PCM 数据
//

#import <Foundation/Foundation.h>
#import "CFManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface CFDirectSource : NSObject <CFFrameSource>

- (instancetype)initWithPort:(uint16_t)port;

/// 监听端口（面板展示用）
@property (nonatomic, readonly) uint16_t port;

/// 推过来的音频格式（固定值，PC 端按此推）
@property (class, nonatomic, readonly) NSUInteger audioSampleRate;   // 44100
@property (class, nonatomic, readonly) NSUInteger audioChannels;     // 2

/// 是否已收到过音频数据
@property (nonatomic, readonly) BOOL hasAudio;

/// 取最多 bytes 字节的 PCM（取走即消耗）；缓冲为空返回 nil
- (nullable NSData *)takeAudioBytes:(NSUInteger)bytes;

@end

NS_ASSUME_NONNULL_END
