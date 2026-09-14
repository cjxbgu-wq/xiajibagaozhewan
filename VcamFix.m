//
//  VcamFix.m — 用补丁方式实现源码"vcamSelfTextOK 兜底 + 播放器状态自愈"
//
//  核心逻辑（等价于源码 vcamSelfTextOK 返回 YES 的效果）:
//  1. 每 0.1s 无条件刷 _licGate/_licMark = YES (等价 vcamSelfTextOK 恒 YES)
//  2. 检测 plist.enabled 与 _enabled 不一致 → 调源码 setEnabled:
//  3. ★ 检测 plist=YES、_enabled=YES 但播放器卡死 (fc 不涨 且 live=nil)
//     → 强制走 setEnabled:NO → 0.3s → setEnabled:YES 完整重载链路
//     (这是"源码 setEnabled:YES 因为 _enabled 已是 YES 而 early-return"的补丁)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VCamNotify.h"

static dispatch_source_t gTimerMD = nil;
static dispatch_source_t gTimerSB = nil;

#pragma mark - 日志（/tmp + DCIM 双写）

static void VcamFix_Log(NSString *msg) {
    NSString *entry = [NSString stringWithFormat:@"[%@][fix] %@\n", [NSDate date], msg];
    NSArray *paths = @[
        @"/tmp/vcam_fix_log.txt",
        @"/var/mobile/Media/DCIM/vcam_fix_log.txt",
    ];
    for (NSString *p in paths) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                if ([entry writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) break;
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
                break;
            }
        } @catch (...) {}
    }
}

#pragma mark - 类名兼容

static Class VcamFix_BallClass(void) {
    Class c = NSClassFromString(@"Jx6");
    return c ?: NSClassFromString(@"VCamFloatingBall");
}
static id VcamFix_BallInstance(void) {
    Class c = VcamFix_BallClass();
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    IMP f = [c methodForSelector:s];
    return f ? ((id(*)(id,SEL))f)(c, s) : nil;
}
static Class VcamFix_CoreClass(void) {
    Class c = NSClassFromString(@"Qz1");
    return c ?: NSClassFromString(@"VCamCore");
}
static id VcamFix_CoreInstance(void) {
    Class c = VcamFix_CoreClass();
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    IMP f = [c methodForSelector:s];
    return f ? ((id(*)(id,SEL))f)(c, s) : nil;
}

static NSString *VcamFix_PlistPath(void) { return @"/var/mobile/Media/DCIM/vc.plist"; }
static BOOL VcamFix_ReadEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}

#pragma mark - ★ 核心修复：门禁 + 播放器状态自愈

static void VcamFix_SyncEnabled(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;
    uint8_t *base = (uint8_t *)(__bridge void *)core;

    // 只在 mediaserverd 里操作
    Ivar ivMd = class_getInstanceVariable(cls, "_isMediaserverdProcess");
    if (!ivMd) return;
    if (!*(BOOL *)(base + ivar_getOffset(ivMd))) return;

    // 1. 无条件刷门禁（等价源码 vcamSelfTextOK 恒 YES）
    Ivar ivG = class_getInstanceVariable(cls, "_licGate");
    Ivar ivM = class_getInstanceVariable(cls, "_licMark");
    if (ivG) *(BOOL *)(base + ivar_getOffset(ivG)) = YES;
    if (ivM) *(BOOL *)(base + ivar_getOffset(ivM)) = YES;

    SEL sSet = NSSelectorFromString(@"setEnabled:");
    if (![core respondsToSelector:sSet]) return;
    IMP impSet = [core methodForSelector:sSet];
    if (!impSet) return;

    BOOL plistEn = VcamFix_ReadEnabled();
    Ivar ivEn = class_getInstanceVariable(cls, "_enabled");
    if (!ivEn) return;
    BOOL cur = *(BOOL *)(base + ivar_getOffset(ivEn));

    // 2. plist 与 _enabled 不一致 → 调源码 setEnabled:
    if (cur != plistEn) {
        ((void(*)(id,SEL,BOOL))impSet)(core, sSet, plistEn);
        VcamFix_Log([NSString stringWithFormat:@"setEnabled:%d (state mismatch)", (int)plistEn]);
        return;
    }

    // 3. plist=YES 且 _enabled=YES，但播放器卡死 → 强制 disable→enable
    if (!plistEn || !cur) return;

    CVPixelBufferRef live = NULL;
    Ivar ivLiveY = class_getInstanceVariable(cls, "_liveYUVPixelBuffer");
    if (ivLiveY) live = *(CVPixelBufferRef *)(base + ivar_getOffset(ivLiveY));

    id player = nil;
    @try { player = [core valueForKey:@"videoPlayer"]; } @catch (...) {}
    if (!player) return;

    uint64_t fc = 0;
    Ivar ivFc = class_getInstanceVariable([player class], "_frameCount");
    if (!ivFc) ivFc = class_getInstanceVariable([player class], "frameCount");
    if (ivFc) fc = *(uint64_t *)((uint8_t *)(__bridge void *)player + ivar_getOffset(ivFc));

    static uint64_t lastFc = 0;
    static int stuckTicks = 0;
    static CFAbsoluteTime lastForceAt = 0;

    if (fc == lastFc && !live) {
        stuckTicks++;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        // 卡死 2s (20 拍 × 0.1s)，且距上次强制 > 5s
        if (stuckTicks >= 20 && now - lastForceAt > 5.0) {
            lastForceAt = now;
            stuckTicks = 0;
            VcamFix_Log([NSString stringWithFormat:
                @"PLAYER STUCK (fc=%llu live=nil for 2s), force disable→enable",
                (unsigned long long)fc]);
            ((void(*)(id,SEL,BOOL))impSet)(core, sSet, NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                ((void(*)(id,SEL,BOOL))impSet)(core, sSet, YES);
                VcamFix_Log(@"forced re-enable done");
            });
        }
    } else {
        stuckTicks = 0;
    }
    lastFc = fc;
}

#pragma mark - render 入口刷门禁（防 polling 中途翻转）

static void (*gOrig_render)(id, SEL, CVPixelBufferRef, double) = NULL;
static void VcamFix_render(id self, SEL _cmd, CVPixelBufferRef pb, double pts) {
    static Ivar ivG = NULL, ivM = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = VcamFix_CoreClass();
        if (c) {
            ivG = class_getInstanceVariable(c, "_licGate");
            ivM = class_getInstanceVariable(c, "_licMark");
        }
    });
    uint8_t *b = (uint8_t *)(__bridge void *)self;
    if (ivG) *(BOOL *)(b + ivar_getOffset(ivG)) = YES;
    if (ivM) *(BOOL *)(b + ivar_getOffset(ivM)) = YES;
    if (gOrig_render) gOrig_render(self, _cmd, pb, pts);
}

#pragma mark - VCamHidePatch 三指呼出 + hideBtn

static void VcamFix_hideBall(Class self, SEL _cmd) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @YES;
        [d writeToFile:VcamFix_PlistPath() atomically:YES];
    } @catch (...) {}
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    @try {
        UIView *bv = [ball valueForKey:@"ballView"];
        UIView *pv = [ball valueForKey:@"panelView"];
        if (bv) bv.hidden = YES;
        if (pv) pv.hidden = YES;
        [ball setValue:@NO forKey:@"panelVisible"];
    } @catch (...) {}
}
static void VcamFix_showBall(Class self, SEL _cmd) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @NO;
        [d writeToFile:VcamFix_PlistPath() atomically:YES];
    } @catch (...) {}
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    @try {
        UIView *bv = [ball valueForKey:@"ballView"];
        if (bv) bv.hidden = NO;
    } @catch (...) {}
}
static void VcamFix_pollHide(Class self, SEL _cmd) {
    static BOOL injected = NO;
    if (injected) return;
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIView *cpv = nil;
    @try { cpv = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    if (!cpv) return;
    if ([cpv viewWithTag:0x56434D31]) { injected = YES; return; }

    CGFloat maxBottom = -1, cellH = 0;
    for (UIView *sub in cpv.subviews) {
        if (![sub isKindOfClass:[UIButton class]]) continue;
        CGRect f = sub.frame;
        CGFloat b = f.origin.y + f.size.height;
        if (b > maxBottom) { maxBottom = b; cellH = f.size.height; }
    }
    if (maxBottom < 0) return;

    CGFloat pad = 10;
    CGFloat cw = cpv.frame.size.width - pad * 2;
    UIButton *hb = [UIButton buttonWithType:UIButtonTypeSystem];
    hb.tag = 0x56434D31;
    hb.frame = CGRectMake(pad, maxBottom + 8, cw, cellH);
    hb.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
    hb.layer.cornerRadius = 9;
    hb.layer.masksToBounds = YES;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImage *sym = [UIImage systemImageNamed:@"eye.slash.fill" withConfiguration:cfg];
    if (sym) {
        [hb setImage:sym forState:UIControlStateNormal];
        hb.tintColor = [UIColor whiteColor];
        hb.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
    } else {
        [hb setTitle:@"隐" forState:UIControlStateNormal];
        [hb setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        hb.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    }
    [hb addTarget:self action:NSSelectorFromString(@"vchp_hideTapped") forControlEvents:UIControlEventTouchUpInside];
    [cpv addSubview:hb];

    CGRect cf = cpv.frame;
    cf.size.height = maxBottom + 8 + cellH + 8;
    cpv.frame = cf;
    UIView *pv = nil;
    @try { pv = [ball valueForKey:@"panelView"]; } @catch (...) {}
    if (pv) {
        CGRect pf = pv.frame;
        pf.size.height = cf.origin.y + cf.size.height + 10;
        pv.frame = pf;
        SEL s = NSSelectorFromString(@"updatePanelPosition");
        if ([ball respondsToSelector:s]) ((void(*)(id,SEL))[ball methodForSelector:s])(ball, s);
    }
    injected = YES;
}

#pragma mark - 控制 tab 切换

@interface VcamFixCtrlTarget : NSObject
+ (instancetype)shared;
- (void)controlTabTapped:(id)sender;
@end
@implementation VcamFixCtrlTarget
+ (instancetype)shared {
    static VcamFixCtrlTarget *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VcamFixCtrlTarget alloc] init]; });
    return inst;
}
- (void)controlTabTapped:(id)sender {
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIView *panelView = nil, *controlPage = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    if (!panelView || !controlPage) return;
    controlPage.hidden = NO;
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;
    UIButton *ctrlBtn = nil;
    @try { ctrlBtn = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    UIButton *actBtn = [panelView viewWithTag:0x56435041];
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = active;
    if (actBtn)  actBtn.backgroundColor  = inactive;
    CGFloat targetH = controlPage.frame.origin.y + controlPage.frame.size.height + 10;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = panelView.frame;
        f.size.height = targetH;
        panelView.frame = f;
    }];
}
@end

static void VcamFix_EnsureControlTabTarget(void) {
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIButton *ctrlBtn = nil;
    @try { ctrlBtn = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    if (!ctrlBtn) return;
    BOOL has = NO;
    for (id t in [ctrlBtn allTargets]) {
        if ([t isKindOfClass:[VcamFixCtrlTarget class]]) { has = YES; break; }
    }
    if (!has) {
        [ctrlBtn addTarget:[VcamFixCtrlTarget shared]
                    action:@selector(controlTabTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    }
}

#pragma mark - 入口

__attribute__((constructor, used))
static void VcamFixInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        BOOL isMd    = [proc isEqualToString:@"mediaserverd"];
        BOOL isLskdd = [proc isEqualToString:@"lskdd"];
        BOOL isSB    = [proc isEqualToString:@"SpringBoard"];

        if (isMd || isLskdd) {
            VcamFix_Log([NSString stringWithFormat:@"md init pid=%d", getpid()]);

            Class coreCls = VcamFix_CoreClass();
            if (coreCls) {
                Method mr = class_getInstanceMethod(coreCls, NSSelectorFromString(@"renderReplacementToPixelBuffer:pts:"));
                if (mr) {
                    gOrig_render = (void (*)(id,SEL,CVPixelBufferRef,double))method_getImplementation(mr);
                    method_setImplementation(mr, (IMP)VcamFix_render);
                }
            }

            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            gTimerMD = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerMD,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                (uint64_t)(0.1 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerMD, ^{
                @autoreleasepool { VcamFix_SyncEnabled(); }
            });
            dispatch_resume(gTimerMD);

        } else if (isSB) {
            VcamFix_Log([NSString stringWithFormat:@"sb init pid=%d", getpid()]);

            Class hideCls = NSClassFromString(@"VCamHidePatch");
            if (hideCls) {
                Method m1 = class_getClassMethod(hideCls, NSSelectorFromString(@"hideBall"));
                if (m1) method_setImplementation(m1, (IMP)VcamFix_hideBall);
                Method m2 = class_getClassMethod(hideCls, NSSelectorFromString(@"showBall"));
                if (m2) method_setImplementation(m2, (IMP)VcamFix_showBall);
                Method m3 = class_getClassMethod(hideCls, NSSelectorFromString(@"pollForPanelAndInjectButton"));
                if (m3) method_setImplementation(m3, (IMP)VcamFix_pollHide);
            }
            dispatch_queue_t q = dispatch_get_main_queue();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           q, ^{ VcamFix_EnsureControlTabTarget(); });
            gTimerSB = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerSB,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerSB, ^{
                @autoreleasepool { VcamFix_EnsureControlTabTarget(); }
            });
            dispatch_resume(gTimerSB);
        }
    }
}
