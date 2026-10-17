//
//  CFMenu.h — 悬浮控制面板（UIWindow，可拖拽，可折叠成小气泡）
//

#import <Foundation/Foundation.h>
#import "CFManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface CFMenu : NSObject

+ (instancetype)shared;

- (void)buildIfNeeded;   ///< 首次调用时建窗（主线程）
- (void)toggle;          ///< 显示/隐藏
- (void)refresh;         ///< 刷新所有控件状态

@end

NS_ASSUME_NONNULL_END
