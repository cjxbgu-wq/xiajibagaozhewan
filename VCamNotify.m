//
//  VCamNotify.m
//  plist 读写 + Darwin 通知 + 主轮询
//

#import "VCamNotify.h"
#include <string.h>
#include <unistd.h>

NSString *const VCamNotifyReloadMedia = @"com.vcam.ios.media.reload";
NSString *const VCamNotifyLiveChanged = @"com.vcam.ios.live.changed";
NSString *const VCamPlistPath         = @"/var/mobile/Media/DCIM/vc.plist";
NSString *const VCamStateBackupPath   = @"/var/mobile/vc.plist";

// ============================================================
//  日志
// ============================================================
static BOOL vcam_log_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
            if (d) cached = d[@"logEnabled"] ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) {}
    }
    return cached == 1;
}

extern BOOL vcam_log_budget_take(void);

static void vcam_notify_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_notify_log.txt";
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// ============================================================
//  Darwin 通知回调
// ============================================================
@interface VCamNotify (Private)
- (void)dispatchCallbackForName:(NSString *)name;
@end

static void vcam_darwin_callback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (observer && name) {
        VCamNotify *notify = (__bridge VCamNotify *)observer;
        [notify dispatchCallbackForName:(__bridge NSString *)name];
    }
}

// ============================================================
//  类扩展
// ============================================================
@interface VCamNotify ()
@property (nonatomic, strong) dispatch_queue_t notifyQueue;
@property (nonatomic, strong) NSMutableDictionary *callbacks;
@property (nonatomic, strong) NSLock *callbackLock;
@property (nonatomic, strong) NSMutableDictionary *darwinTokens;
@property (nonatomic, strong) dispatch_source_t pollingTimer;
@property (nonatomic, copy)   void(^pollingCallback)(BOOL enabled);
@property (nonatomic, assign) BOOL pollingActive;
@end

// ============================================================
//  @implementation
// ============================================================
@implementation VCamNotify

+ (instancetype)sharedInstance {
    static VCamNotify *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamNotify alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _notifyQueue = dispatch_queue_create("com.vcam.notify", DISPATCH_QUEUE_SERIAL);
        _callbacks = [[NSMutableDictionary alloc] init];
        _callbackLock = [[NSLock alloc] init];
        _darwinTokens = [[NSMutableDictionary alloc] init];
        _pollingActive = NO;
    }
    return self;
}

#pragma mark - Darwin 通知

- (void)postNotification:(NSString *)name {
    if (!name) return;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name, NULL, NULL, TRUE);
}

- (NSInteger)registerForNotification:(NSString *)name callback:(VCamNotifyCallback)callback {
    if (!name || !callback) return -1;
    NSInteger token = [self nextTokenForName:name];
    __block VCamNotifyCallback blockCallback = [callback copy];
    NSDictionary *wrapper = @{@"token": @(token), @"callback": blockCallback};
    [_callbackLock lock];
    NSMutableArray *arr = _callbacks[name];
    if (!arr) {
        arr = [[NSMutableArray alloc] init];
        _callbacks[name] = arr;
    }
    [arr addObject:wrapper];
    [_callbackLock unlock];
    if (arr.count == 1) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge void *)self, vcam_darwin_callback,
            (__bridge CFStringRef)name, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return token;
}

- (void)unregisterNotification:(NSString *)name token:(NSInteger)token {
    if (!name) return;
    [_callbackLock lock];
    NSMutableArray *arr = _callbacks[name];
    if (arr) {
        for (NSInteger i = arr.count - 1; i >= 0; i--) {
            if ([arr[i][@"token"] integerValue] == token) {
                [arr removeObjectAtIndex:i];
            }
        }
        if (arr.count == 0) {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge void *)self, (__bridge CFStringRef)name, NULL);
            [_callbacks removeObjectForKey:name];
        }
    }
    [_callbackLock unlock];
}

- (NSInteger)nextTokenForName:(NSString *)name {
    NSNumber *current = _darwinTokens[name];
    NSInteger next = current ? [current integerValue] + 1 : 1;
    _darwinTokens[name] = @(next);
    return next;
}

- (void)dispatchCallbackForName:(NSString *)name {
    [_callbackLock lock];
    NSArray *arr = [_callbacks[name] copy];
    [_callbackLock unlock];
    for (NSDictionary *wrapper in arr) {
        VCamNotifyCallback cb = wrapper[@"callback"];
        if (cb) {
            dispatch_async(_notifyQueue, ^{ cb(name); });
        }
    }
}

#pragma mark - plist 轮询

- (void)startPollingWithInterval:(NSTimeInterval)interval callback:(void(^)(BOOL enabled))callback {
    if (_pollingActive) return;
    _pollingActive = YES;
    _pollingCallback = [callback copy];
    _pollingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _notifyQueue);
    uint64_t intervalNs = interval * NSEC_PER_SEC;
    dispatch_source_set_timer(_pollingTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 2);
    dispatch_source_set_event_handler(_pollingTimer, ^{
        BOOL enabled = [VCamNotify isPlistEnabled];
        if (self->_pollingCallback) self->_pollingCallback(enabled);
    });
    dispatch_resume(_pollingTimer);
    vcam_notify_log([NSString stringWithFormat:@"[vcam] polling started interval=%.2fs", interval]);
}

- (void)stopPolling {
    if (_pollingTimer) {
        dispatch_source_cancel(_pollingTimer);
        _pollingTimer = nil;
    }
    _pollingActive = NO;
    _pollingCallback = nil;
}

#pragma mark - plist 读写（替换开关 / 视频源）

+ (BOOL)isPlistEnabled {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
    NSNumber *enabled = dict[@"enabled"];
    return enabled ? [enabled boolValue] : NO;
}

+ (void)setPlistEnabled:(BOOL)enabled {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"enabled"] = @(enabled);
    [dict writeToFile:VCamPlistPath atomically:YES];
    [dict writeToFile:VCamStateBackupPath atomically:YES];
}

+ (NSString *)activePlaybackPath {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return dict[@"activePlaybackPath"];
}

+ (void)setActivePlaybackPath:(NSString *)path {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    if (path) dict[@"activePlaybackPath"] = path;
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - plist 读写（旋转/镜像）

+ (NSInteger)plistRotation {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *rot = dict[@"manualRotation"];
    return rot ? [rot integerValue] : 0;
}

+ (void)setPlistRotation:(NSInteger)degrees {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"manualRotation"] = @(degrees);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (BOOL)plistMirrored {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *m = dict[@"mirrored"];
    return m ? [m boolValue] : NO;
}

+ (void)setPlistMirrored:(BOOL)mirrored {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"mirrored"] = @(mirrored);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - plist 读写（缩放/平移）

+ (double)plistPanX {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userPanX"];
    return v ? [v doubleValue] : 0.0;
}
+ (void)setPlistPanX:(double)panX {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanX"] = @(panX);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (double)plistPanY {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userPanY"];
    return v ? [v doubleValue] : 0.0;
}
+ (void)setPlistPanY:(double)panY {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanY"] = @(panY);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (double)plistZoom {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userZoom"];
    return v ? [v doubleValue] : 1.0;
}
+ (void)setPlistZoom:(double)zoom {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userZoom"] = @(zoom);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (void)resetPlistTransform {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanX"] = @0.0;
    dict[@"userPanY"] = @0.0;
    dict[@"userZoom"] = @1.0;
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (BOOL)plistFrontPanFix {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"frontPanFix"] boolValue];
}
+ (void)setPlistFrontPanFix:(BOOL)fix {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"frontPanFix"] = @(fix);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - plist 读写（播放控制）

+ (BOOL)plistPaused {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"paused"] boolValue];
}
+ (void)setPlistPaused:(BOOL)paused {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"paused"] = @(paused);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (NSInteger)plistRestartToken {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"restartToken"] integerValue];
}
+ (void)bumpRestartToken {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    NSInteger token = [dict[@"restartToken"] integerValue] + 1;
    dict[@"restartToken"] = @(token);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 密钥验证（精简版：恒放行）

+ (BOOL)vcamLicenseValid { return YES; }
+ (BOOL)vcamCrossDeviceCodeOK { return YES; }
+ (NSString *)vcamDeviceCode { return @"0000000000000000"; }
+ (BOOL)vcamActivateLicense:(NSString *)input { return NO; }
+ (void)vcamPublishDeviceCode {}
+ (double)vcamLicenseTableDouble:(NSUInteger)idx { return 0.0; }
+ (uint32_t)vcamLicenseTableInt:(NSUInteger)idx { return 0; }
+ (BOOL)vcamLicenseDecodeT:(uint32_t *)outT { return NO; }

@end
