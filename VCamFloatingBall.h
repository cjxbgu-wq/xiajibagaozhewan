//
//  VCamFloatingBall.h
//  悬浮球 UI（圆形按钮 + 面板）
//

#import <Foundation/Foundation.h>

@interface VCamFloatingBall : NSObject

+ (instancetype)sharedInstance;

- (void)showFloatingBall;
- (void)hideFloatingBall;

@end
