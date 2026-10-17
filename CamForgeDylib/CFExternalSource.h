//
//  CFExternalSource.h — USB / 外接摄像头直通（iOS 17+ AVCaptureDeviceTypeExternal）
//
//  说明：iOS 没有通用 UVC 驱动，唯一公开路径是 iOS 17 起的外部摄像头 API
//  （USB-C 外接 UVC 摄像头，iPhone 15 / iPad 支持）。旧系统或无设备时给出明确提示，
//  不做任何越狱层 USB 协议栈的复刻。
//

#import <Foundation/Foundation.h>
#import "CFManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface CFExternalSource : NSObject <CFFrameSource>

/// 当前系统是否具备外部摄像头能力（iOS 17+）
+ (BOOL)supported;

@end

NS_ASSUME_NONNULL_END
