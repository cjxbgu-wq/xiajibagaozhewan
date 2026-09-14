//
//  VcamFix.m — 对精简版源码的运行时补丁（源码零更改）
//
//  仅修复用户提出的问题:
//  1. 视频静止不播放
//  2. 点 + 键面板消失（hideBtn 覆盖在 + 上导致）
//  3. 隐藏按钮失效
//  4. 动作按钮失效 / "退出动作"消失
//  5. 隐藏后三指长按无法呼出悬浮球
//
//  不新增任何功能按钮, 不动 −/+/旋转/禁用视频 现有布局
//
//  用法: 在 Makefile 的 VcamMax_FILES 里追加 VcamFix.m 即可
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <unistd.h>
#include <notify.h>
#import "VCamNotify.h"

#pragma mark - 文件级保活

static dispatch_source_t gVcamFixUITimer      = nil;
static dispatch_source_t gVcamFixEnabledTimer = nil;
static UIWindow         *gVcamFixThreeFingerWindow = nil;

#pragma mark - Tag 常量

static const NSInteger kTagHideBtn    = 0x56434D31;
static const NSInteger kTagActionTab  = 0x56435041;
static const NSInteger kTagActionPage = 0x56435042;
static const NSInteger kTagExitAction = 0x46455849;

#pragma mark - 日志

static void VcamFix_Log(NSString *msg) {
    NSString *entry = [NSString stringWithFormat:@"[%@][fix] %@\n", [NSDate date], msg];
    NSArray *paths = @[@"/tmp/vcam_fix_log.txt",
                       @"/var/mobile/Media/DCIM/vcam_fix_log.txt"];
    for (NSString *path in paths) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
            return;
        } @catch (NSException *e) {}
    }
}

#pragma mark - 类名兼容

static Class VcamFix_BallClass(void) {
    Class cls = NSClassFromString(@"Jx6");
    if (cls) return cls;
    return NSClassFromString(@"VCamFloatingBall");
}

static id VcamFix_BallInstance(void) {
    Class cls = VcamFix_BallClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    IMP imp = [cls methodForSelector:sel];
    if (!imp) return nil;
    return ((id (*)(id, SEL))imp)(cls, sel);
}

static Class VcamFix_CoreClass(void) {
    Class cls = NSClassFromString(@"Qz1");
    if (cls) return cls;
    return NSClassFromString(@"VCamCore");
}

static id VcamFix_CoreInstance(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    IMP imp = [cls methodForSelector:sel];
    if (!imp) return nil;
    return ((id (*)(id, SEL))imp)(cls, sel);
}

#pragma mark - plist

static NSString *VcamFix_PlistPath(void) { return @"/var/mobile/Media/DCIM/vc.plist"; }

static BOOL VcamFix_ReadPlistEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSDictionary dictionaryWithContentsOfFile:
                     @"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}

static BOOL VcamFix_ReadPlistBallHidden(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSDictionary dictionaryWithContentsOfFile:
                     @"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
        if (d) return [d[@"ballHidden"] boolValue];
    } @catch (...) {}
    return NO;
}

static void VcamFix_WritePlistBallHidden(BOOL hidden) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @(hidden);
        [d writeToFile:VcamFix_PlistPath() atomically:YES];
    } @catch (...) {}
}

#pragma mark - swizzle: render 入口刷门禁

static void (*gOrig_renderPts)(id, SEL, CVPixelBufferRef, double) = NULL;

static void VcamFix_renderPts(id self, SEL _cmd, CVPixelBufferRef pb, double pts) {
    static Ivar ivGate = NULL, ivMark = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = VcamFix_CoreClass();
        if (cls) {
            ivGate = class_getInstanceVariable(cls, "_licGate");
            ivMark = class_getInstanceVariable(cls, "_licMark");
        }
    });
    uint8_t *base = (uint8_t *)(__bridge void *)self;
    if (ivGate) *(BOOL *)(base + ivar_getOffset(ivGate)) = YES;
    if (ivMark) *(BOOL *)(base + ivar_getOffset(ivMark)) = YES;
    if (gOrig_renderPts) gOrig_renderPts(self, _cmd, pb, pts);
}

#pragma mark - swizzle: setEnabled 与 plist 不一致时拦截

static void (*gOrig_setEnabled)(id, SEL, BOOL) = NULL;

static void VcamFix_setEnabled(id self, SEL _cmd, BOOL enabled) {
    BOOL plistEn = VcamFix_ReadPlistEnabled();
    if (enabled != plistEn) return;
    if (gOrig_setEnabled) gOrig_setEnabled(self, _cmd, enabled);
}

#pragma mark - 问题 1: 0.1s timer 自愈

static void VcamFix_SyncEnabled(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;

    uint8_t *base = (uint8_t *)(__bridge void *)core;

    Ivar ivMd = class_getInstanceVariable(cls, "_isMediaserverdProcess");
    if (!ivMd) return;
    if (!*(BOOL *)(base + ivar_getOffset(ivMd))) return;

    Ivar ivEn   = class_getInstanceVariable(cls, "_enabled");
    Ivar ivPre  = class_getInstanceVariable(cls, "_prerenderActive");
    Ivar ivLive = class_getInstanceVariable(cls, "_liveYUVPixelBuffer");
    if (!ivEn || !ivPre || !ivLive) return;

    BOOL cur     = *(BOOL *)(base + ivar_getOffset(ivEn));
    BOOL pre     = *(BOOL *)(base + ivar_getOffset(ivPre));
    CVPixelBufferRef live = *(CVPixelBufferRef *)(base + ivar_getOffset(ivLive));
    BOOL plistEn = VcamFix_ReadPlistEnabled();

    if (cur != plistEn) {
        SEL sSet = NSSelectorFromString(@"setEnabled:");
        if ([core respondsToSelector:sSet]) {
            ((void(*)(id, SEL, BOOL))[core methodForSelector:sSet])(core, sSet, plistEn);
            VcamFix_Log([NSString stringWithFormat:
                @"[vcam][fix] enabled sync %d -> %d", cur, plistEn]);
        }
        return;
    }

    if (plistEn && cur && !pre) {
        SEL sStart = NSSelectorFromString(@"startPrerenderThread");
        if ([core respondsToSelector:sStart]) {
            ((void(*)(id,SEL))[core methodForSelector:sStart])(core, sStart);
            VcamFix_Log(@"[vcam][fix] restart prerender thread");
        }
        id player = nil;
        @try { player = [core valueForKey:@"videoPlayer"]; } @catch (...) {}
        if (player) {
            SEL sDecode = NSSelectorFromString(@"startDecodingThread");
            if ([player respondsToSelector:sDecode]) {
                ((void(*)(id,SEL))[player methodForSelector:sDecode])(player, sDecode);
            }
        }
        return;
    }

    static CFAbsoluteTime liveNilSince = 0;
    if (plistEn && cur && pre && live == NULL) {
        if (liveNilSince == 0) {
            liveNilSince = CFAbsoluteTimeGetCurrent();
        } else if (CFAbsoluteTimeGetCurrent() - liveNilSince > 2.0) {
            VcamFix_Log(@"[vcam][fix] live nil >2s, force disable->enable reset");
            SEL sSet = NSSelectorFromString(@"setEnabled:");
            if (gOrig_setEnabled) {
                gOrig_setEnabled(core, sSet, NO);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gOrig_setEnabled) gOrig_setEnabled(core, sSet, YES);
                    VcamFix_Log(@"[vcam][fix] reset complete");
                });
            }
            liveNilSince = 0;
        }
    } else {
        liveNilSince = 0;
    }
}

#pragma mark - 问题 5: 三指长按呼出 (VcamFix 自建, 不依赖 VCamHidePatch)

@interface VcamFixThreeFingerWindow : UIWindow
@end
@implementation VcamFixThreeFingerWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 对齐源码 VCamThreeFingerWindow: 屏幕下方 25% 命中, 其它穿透
    CGFloat areaTop = self.bounds.size.height * 0.75;
    if (point.y < areaTop) return nil;
    return [super hitTest:point withEvent:event];
}
@end

@interface VcamFixGestureTarget : NSObject
+ (instancetype)shared;
- (void)onThreeFingerLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation VcamFixGestureTarget
+ (instancetype)shared {
    static VcamFixGestureTarget *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VcamFixGestureTarget alloc] init]; });
    return inst;
}
- (void)onThreeFingerLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    VcamFix_Log(@"[vcam][fix] three-finger long press -> show ball");

    // 写 plist ballHidden=NO
    VcamFix_WritePlistBallHidden(NO);

    // 直接显示 ballView/panelView
    id ball = VcamFix_BallInstance();
    if (ball) {
        @try {
            UIView *ballView = [ball valueForKey:@"ballView"];
            if (ballView) ballView.hidden = NO;
        } @catch (...) {}
    }

    // 关闭三指 window
    if (gVcamFixThreeFingerWindow) gVcamFixThreeFingerWindow.hidden = YES;
}
@end

static void VcamFix_EnsureThreeFingerWindow(void) {
    if (gVcamFixThreeFingerWindow) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return;

    gVcamFixThreeFingerWindow = [[VcamFixThreeFingerWindow alloc] initWithWindowScene:scene];
    gVcamFixThreeFingerWindow.windowLevel = UIWindowLevelAlert + 1000;
    gVcamFixThreeFingerWindow.backgroundColor = [UIColor clearColor];
    gVcamFixThreeFingerWindow.hidden = YES;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = YES;
    gVcamFixThreeFingerWindow.rootViewController = vc;

    // 对齐源码 VCamHidePatch.m 的手势参数: 3 指 1.5s
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[VcamFixGestureTarget shared]
                action:@selector(onThreeFingerLongPress:)];
    lp.numberOfTouchesRequired = 3;
    lp.minimumPressDuration   = 1.5;
    lp.allowableMovement      = 200.0;
    lp.cancelsTouchesInView   = NO;
    [gVcamFixThreeFingerWindow addGestureRecognizer:lp];
    VcamFix_Log(@"[vcam][fix] three-finger window ready");
}

static void VcamFix_SyncThreeFingerWindow(void) {
    BOOL hidden = VcamFix_ReadPlistBallHidden();
    VcamFix_EnsureThreeFingerWindow();
    if (!gVcamFixThreeFingerWindow) return;
    if (hidden && gVcamFixThreeFingerWindow.hidden) {
        gVcamFixThreeFingerWindow.hidden = NO;
        VcamFix_Log(@"[vcam][fix] three-finger window activated (ballHidden=YES)");
    } else if (!hidden && !gVcamFixThreeFingerWindow.hidden) {
        gVcamFixThreeFingerWindow.hidden = YES;
    }
}

#pragma mark - 控制页 target 桥

@interface VcamFixCtrlTarget : NSObject
+ (instancetype)shared;
- (void)onControlTabTapped:(id)sender;
- (void)onActionTabTapped:(id)sender;
- (void)onHideTapped:(id)sender;
- (void)onExitActionTapped:(id)sender;
@end

@implementation VcamFixCtrlTarget

+ (instancetype)shared {
    static VcamFixCtrlTarget *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VcamFixCtrlTarget alloc] init]; });
    return inst;
}

- (void)onControlTabTapped:(id)sender {
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIView *panelView = nil, *controlPage = nil;
    UIButton *ctrlBtn = nil;
    @try { panelView   = [ball valueForKey:@"panelView"]; }       @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    @try { ctrlBtn     = [ball valueForKey:@"tabControlBtn"]; }   @catch (...) {}
    if (!panelView || !controlPage) return;
    controlPage.hidden = NO;
    UIView *actionPage = [panelView viewWithTag:kTagActionPage];
    if (actionPage) actionPage.hidden = YES;
    UIButton *actBtn = [panelView viewWithTag:kTagActionTab];
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = active;
    if (actBtn)  actBtn.backgroundColor  = inactive;
}

- (void)onActionTabTapped:(id)sender {
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIView *panelView = nil, *controlPage = nil;
    UIButton *ctrlBtn = nil;
    @try { panelView   = [ball valueForKey:@"panelView"]; }       @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    @try { ctrlBtn     = [ball valueForKey:@"tabControlBtn"]; }   @catch (...) {}
    if (!panelView || !controlPage) return;
    UIView *actionPage = [panelView viewWithTag:kTagActionPage];
    UIButton *actBtn = [panelView viewWithTag:kTagActionTab];
    if (!actionPage || !actBtn) return;
    controlPage.hidden = YES;
    actionPage.hidden = NO;
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = inactive;
    if (actBtn)  actBtn.backgroundColor  = active;
}

// 隐藏按钮: 直接隐藏 + 写 plist + 激活三指 window
- (void)onHideTapped:(id)sender {
    VcamFix_WritePlistBallHidden(YES);

    id ball = VcamFix_BallInstance();
    if (ball) {
        @try {
            UIView *ballView  = [ball valueForKey:@"ballView"];
            UIView *panelView = [ball valueForKey:@"panelView"];
            if (ballView)  ballView.hidden  = YES;
            if (panelView) panelView.hidden = YES;
            [ball setValue:@NO forKey:@"panelVisible"];
        } @catch (...) {}
    }

    // 立即激活三指 window
    VcamFix_EnsureThreeFingerWindow();
    if (gVcamFixThreeFingerWindow) gVcamFixThreeFingerWindow.hidden = NO;
    VcamFix_Log(@"[vcam][fix] hide button tapped, three-finger window active");
}

// 退出动作 (对齐 FixActionPlayback.fx_exitTapped 语义)
- (void)onExitActionTapped:(id)sender {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"actionActive"] = @0;
        d[@"actionToken"]  = @([d[@"actionToken"] integerValue] + 1);
        [d writeToFile:VcamFix_PlistPath() atomically:YES];
    } @catch (...) {}

    // 通知 mediaserverd 拉取 (对齐源码 fxPostActionNotify 的通知名)
    notify_post("com.gouchun.action");
    VcamFix_Log(@"[vcam][fix] exit-action via notify_post");
}

@end

#pragma mark - UI 补丁

static void VcamFix_PatchUI(void) {
    id ball = VcamFix_BallInstance();
    if (!ball) return;

    UIView *panelView = nil;
    UIButton *ctrlBtn = nil;
    UIView *controlPage = nil;
    @try { panelView   = [ball valueForKey:@"panelView"]; }       @catch (...) {}
    @try { ctrlBtn     = [ball valueForKey:@"tabControlBtn"]; }   @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    if (!panelView || !ctrlBtn || !controlPage) return;

    CGFloat panelW = panelView.frame.size.width;
    CGFloat pad = 10;
    CGFloat contentW = panelW - pad * 2;
    CGFloat tabH = ctrlBtn.frame.size.height;
    CGFloat tabY = ctrlBtn.frame.origin.y;
    CGFloat pageTop = tabY + tabH + 6;

    // ===== 1. tabControlBtn 追加 target =====
    BOOL hasCtrlTarget = NO;
    for (id t in [ctrlBtn allTargets]) {
        if ([t isKindOfClass:[VcamFixCtrlTarget class]]) { hasCtrlTarget = YES; break; }
    }
    if (!hasCtrlTarget) {
        [ctrlBtn addTarget:[VcamFixCtrlTarget shared]
                    action:@selector(onControlTabTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        VcamFix_Log(@"[vcam][fix] tabControlBtn addTarget OK");
    }

    // ===== 2. 清理旧版覆盖在 + 上的 hideBtn =====
    UIButton *oldHide = (UIButton *)[controlPage viewWithTag:kTagHideBtn];
    if (oldHide) {
        BOOL conflicts = NO;
        for (UIView *sub in controlPage.subviews) {
            if (sub == oldHide) continue;
            if (![sub isKindOfClass:[UIButton class]]) continue;
            if (CGRectIntersectsRect(sub.frame, oldHide.frame)) { conflicts = YES; break; }
        }
        if (conflicts) {
            [oldHide removeFromSuperview];
            VcamFix_Log(@"[vcam][fix] removed misplaced old hide button (overlapping +)");
        }
    }

    // ===== 3. 隐藏按钮 (y=166 独立行) =====
    if (![controlPage viewWithTag:kTagHideBtn]) {
        CGFloat hideY = 158 + 8;
        UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        hideBtn.tag = kTagHideBtn;
        hideBtn.frame = CGRectMake(pad, hideY, contentW, 34);
        hideBtn.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
        hideBtn.layer.cornerRadius = 9;
        hideBtn.layer.masksToBounds = YES;
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:14
                                                            weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [UIImage systemImageNamed:@"eye.slash.fill" withConfiguration:cfg];
        if (sym) {
            [hideBtn setImage:sym forState:UIControlStateNormal];
            hideBtn.tintColor = [UIColor whiteColor];
            hideBtn.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
        } else {
            [hideBtn setTitle:@"隐" forState:UIControlStateNormal];
            [hideBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            hideBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        }
        [hideBtn addTarget:[VcamFixCtrlTarget shared]
                    action:@selector(onHideTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [controlPage addSubview:hideBtn];

        controlPage.frame = CGRectMake(controlPage.frame.origin.x,
                                       controlPage.frame.origin.y,
                                       controlPage.frame.size.width,
                                       hideY + 34);
        panelView.frame = CGRectMake(panelView.frame.origin.x,
                                     panelView.frame.origin.y,
                                     panelView.frame.size.width,
                                     pageTop + (hideY + 34) + pad);
        SEL s = NSSelectorFromString(@"updatePanelPosition");
        if ([ball respondsToSelector:s]) {
            ((void(*)(id,SEL))[ball methodForSelector:s])(ball, s);
        }
        VcamFix_Log(@"[vcam][fix] hide button injected at y=166");
    }

    // ===== 4. 动作 tab (不抢先注入, 等源码 VCamActionPatch) =====
    UIButton *actTab = (UIButton *)[panelView viewWithTag:kTagActionTab];
    if (actTab) {
        BOOL hasMyTarget = NO;
        for (id t in [actTab allTargets]) {
            if ([t isKindOfClass:[VcamFixCtrlTarget class]]) { hasMyTarget = YES; break; }
        }
        if (!hasMyTarget) {
            [actTab addTarget:[VcamFixCtrlTarget shared]
                       action:@selector(onActionTabTapped:)
             forControlEvents:UIControlEventTouchUpInside];
            VcamFix_Log(@"[vcam][fix] action tab target appended");
        }

        UIView *actionPage = [panelView viewWithTag:kTagActionPage];
        if (actionPage && ![actionPage viewWithTag:kTagExitAction]) {
            CGRect f = actionPage.frame;
            f.size.height += 46;
            actionPage.frame = f;

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.tag = kTagExitAction;
            btn.frame = CGRectMake(10, f.size.height - 42, f.size.width - 20, 36);
            [btn setTitle:@"退出动作" forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
            btn.backgroundColor = [UIColor colorWithRed:0.36 green:0.42 blue:0.58 alpha:1.0];
            btn.layer.cornerRadius = 6;
            btn.layer.masksToBounds = YES;
            [btn addTarget:[VcamFixCtrlTarget shared]
                    action:@selector(onExitActionTapped:)
          forControlEvents:UIControlEventTouchUpInside];
            [actionPage addSubview:btn];
            VcamFix_Log(@"[vcam][fix] exit-action button injected");
        }
    }
}

#pragma mark - 入口

__attribute__((constructor, used))
static void VcamFixInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        VcamFix_Log([NSString stringWithFormat:@"[vcam][fix] init in %@ pid=%d",
                     proc, (int)getpid()]);

        BOOL isMd    = [proc isEqualToString:@"mediaserverd"];
        BOOL isLskdd = [proc isEqualToString:@"lskdd"];
        BOOL isSB    = [proc isEqualToString:@"SpringBoard"];

        if (isMd || isLskdd) {
            Class coreCls = VcamFix_CoreClass();
            if (coreCls) {
                SEL sRender = NSSelectorFromString(@"renderReplacementToPixelBuffer:pts:");
                Method mRender = class_getInstanceMethod(coreCls, sRender);
                if (mRender) {
                    gOrig_renderPts = (void (*)(id, SEL, CVPixelBufferRef, double))
                        method_getImplementation(mRender);
                    method_setImplementation(mRender, (IMP)VcamFix_renderPts);
                    VcamFix_Log(@"[vcam][fix] swizzled render OK");
                }
                SEL sSet = NSSelectorFromString(@"setEnabled:");
                Method mSet = class_getInstanceMethod(coreCls, sSet);
                if (mSet) {
                    gOrig_setEnabled = (void (*)(id, SEL, BOOL))method_getImplementation(mSet);
                    method_setImplementation(mSet, (IMP)VcamFix_setEnabled);
                    VcamFix_Log(@"[vcam][fix] swizzled setEnabled: OK");
                }
            }
            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            gVcamFixEnabledTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gVcamFixEnabledTimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                (uint64_t)(0.1 * NSEC_PER_SEC),
                (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gVcamFixEnabledTimer, ^{
                @autoreleasepool { VcamFix_SyncEnabled(); }
            });
            dispatch_resume(gVcamFixEnabledTimer);

        } else if (isSB) {
            dispatch_queue_t q = dispatch_get_main_queue();

            // UI 首拍
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           q, ^{
                VcamFix_PatchUI();
                VcamFix_SyncThreeFingerWindow();
            });

            // 三指 window 同步 (每 0.5s 检查一次 plist ballHidden)
            gVcamFixUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gVcamFixUITimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                (uint64_t)(0.5 * NSEC_PER_SEC),
                (uint64_t)(0.1 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gVcamFixUITimer, ^{
                @autoreleasepool {
                    VcamFix_PatchUI();
                    VcamFix_SyncThreeFingerWindow();
                }
            });
            dispatch_resume(gVcamFixUITimer);
        }
    }
}
