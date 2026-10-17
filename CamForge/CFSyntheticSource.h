//
//  CFSyntheticSource.h — 内置合成测试图案源（零外部依赖，默认源）
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "CFManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface CFSyntheticSource : NSObject <CFFrameSource>
@end

NS_ASSUME_NONNULL_END
