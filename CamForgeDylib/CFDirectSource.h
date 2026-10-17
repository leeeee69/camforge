//
//  CFDirectSource.h — 直连源：PC 经 usbmuxd 把帧推给手机（"USB 直连"）
//
//  机制（与原版同一套传输，协议是我们自己定的）：
//    手机侧监听 127.0.0.1:<port>
//    PC 侧  iproxy <port> <port>  →  跑 tools/cf-push.py 推 JPEG 帧
//
//  帧格式（全部小端）：
//    magic  4B  "CFRM"
//    version1B  0x01
//    type   1B  0x01 = JPEG 整帧
//    resv   2B  0
//    length 4B  负载字节数
//    payload    JPEG 数据
//

#import <Foundation/Foundation.h>
#import "CFManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface CFDirectSource : NSObject <CFFrameSource>

- (instancetype)initWithPort:(uint16_t)port;

/// 监听端口（面板展示用）
@property (nonatomic, readonly) uint16_t port;

@end

NS_ASSUME_NONNULL_END
