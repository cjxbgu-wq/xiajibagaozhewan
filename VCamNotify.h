//
//  VCamNotify.h
//  跨进程通信（plist 读写 + Darwin 通知 + 主轮询）
//

#import <Foundation/Foundation.h>

// Darwin 通知名
extern NSString *const VCamNotifyReloadMedia;   // com.vcam.ios.media.reload
extern NSString *const VCamNotifyLiveChanged;   // com.vcam.ios.live.changed

// plist 路径
extern NSString *const VCamPlistPath;            // /var/mobile/Media/DCIM/vc.plist
extern NSString *const VCamStateBackupPath;      // /var/mobile/vc.plist

typedef void(^VCamNotifyCallback)(NSString *name);

@interface VCamNotify : NSObject

+ (instancetype)sharedInstance;

#pragma mark - Darwin 通知
- (void)postNotification:(NSString *)name;
- (NSInteger)registerForNotification:(NSString *)name callback:(VCamNotifyCallback)callback;
- (void)unregisterNotification:(NSString *)name token:(NSInteger)token;

#pragma mark - plist 轮询
- (void)startPollingWithInterval:(NSTimeInterval)interval
                        callback:(void(^)(BOOL enabled))callback;
- (void)stopPolling;

#pragma mark - plist 读写（替换开关 / 视频源）
+ (BOOL)isPlistEnabled;
+ (void)setPlistEnabled:(BOOL)enabled;
+ (NSString *)activePlaybackPath;
+ (void)setActivePlaybackPath:(NSString *)path;

#pragma mark - plist 读写（旋转/镜像）
+ (NSInteger)plistRotation;
+ (void)setPlistRotation:(NSInteger)degrees;
+ (BOOL)plistMirrored;
+ (void)setPlistMirrored:(BOOL)mirrored;

#pragma mark - plist 读写（缩放/平移）
+ (double)plistPanX;
+ (void)setPlistPanX:(double)panX;
+ (double)plistPanY;
+ (void)setPlistPanY:(double)panY;
+ (double)plistZoom;
+ (void)setPlistZoom:(double)zoom;
+ (void)resetPlistTransform;
+ (BOOL)plistFrontPanFix;
+ (void)setPlistFrontPanFix:(BOOL)fix;

#pragma mark - plist 读写（播放控制）
+ (BOOL)plistPaused;
+ (void)setPlistPaused:(BOOL)paused;
+ (NSInteger)plistRestartToken;
+ (void)bumpRestartToken;

#pragma mark - 密钥验证（精简版：恒放行，保留接口供其他文件调用）
+ (NSString *)vcamDeviceCode;
+ (BOOL)vcamLicenseValid;
+ (BOOL)vcamActivateLicense:(NSString *)input;
+ (void)vcamPublishDeviceCode;
+ (BOOL)vcamCrossDeviceCodeOK;
+ (double)vcamLicenseTableDouble:(NSUInteger)idx;
+ (uint32_t)vcamLicenseTableInt:(NSUInteger)idx;
+ (BOOL)vcamLicenseDecodeT:(uint32_t *)outT;

@end
