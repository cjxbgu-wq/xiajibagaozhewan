//
//  VcamFix.m — 严格照搬完整版源码的 5 处逻辑，源码本体不动
//
//  对应完整版源码的 5 处：
//  1. VCamCore.m 的 _licMark 门禁 → render 每帧刷 + timer 主动调 setEnabled:
//  2. VCamFloatingBall.m 的 controlTabTapped → 用 target 桥实现
//  3. VCamHidePatch.m 的 VCHP_BallClass fallback → swizzle hideBall/showBall
//  4. VCamHidePatch.m 的 hideBtn 位置 → swizzle pollForPanelAndInjectButton
//  5. VCamActionPatch.m 的 actionTabTapped 去掉 lightPage 判空 → swizzle
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VCamNotify.h"

static dispatch_source_t gTimerMD   = nil;
static dispatch_source_t gTimerSB   = nil;
static dispatch_source_t gTimerDiag = nil;

#pragma mark - 日志 (多路径, mediaserverd 沙盒可写)

static void VcamFix_Write(NSString *text, NSArray<NSString *> *paths) {
    for (NSString *p in paths) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                if ([text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
                return;
            }
        } @catch (...) {}
    }
}

static void VcamFix_Log(NSString *msg) {
    NSString *line = [NSString stringWithFormat:@"[%@][fix] %@\n", [NSDate date], msg];
    VcamFix_Write(line, @[
        @"/tmp/vcam_fix_log.txt",
        @"/var/mobile/Media/DCIM/vcam_fix_log.txt",
        @"/private/var/tmp/vcam_fix_log.txt",
    ]);
}

static void VcamFix_DiagLine(NSString *line) {
    VcamFix_Write(line, @[
        @"/tmp/vcam_diag.txt",
        @"/var/mobile/Media/DCIM/vcam_diag.txt",
        @"/private/var/tmp/vcam_diag.txt",
    ]);
}

#pragma mark - 类名兼容 (照搬源码 VCamActionPatch.m 的 fallback)

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

static BOOL VcamFix_ReadEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
        if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}

#pragma mark - 1. VCamCore 门禁 (render 每帧刷 _licGate/_licMark)

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

#pragma mark - 1. timer: 主动调源码 setEnabled: 让它走 enable/disable 分支

// 源码 startStatePolling 里因为 _licMark=NO 导致 effEnabled 恒 NO,
// setEnabled: 从不调用。timer 弥补这个触发路径。
static void VcamFix_SyncEnabled(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;
    uint8_t *base = (uint8_t *)(__bridge void *)core;

    Ivar ivMd = class_getInstanceVariable(cls, "_isMediaserverdProcess");
    if (!ivMd) return;
    if (!*(BOOL *)(base + ivar_getOffset(ivMd))) return;

    // 每拍刷门禁 (防 polling 中途改回 NO)
    Ivar ivG = class_getInstanceVariable(cls, "_licGate");
    Ivar ivM = class_getInstanceVariable(cls, "_licMark");
    if (ivG) *(BOOL *)(base + ivar_getOffset(ivG)) = YES;
    if (ivM) *(BOOL *)(base + ivar_getOffset(ivM)) = YES;

    Ivar ivEn = class_getInstanceVariable(cls, "_enabled");
    if (!ivEn) return;
    BOOL cur     = *(BOOL *)(base + ivar_getOffset(ivEn));
    BOOL plistEn = VcamFix_ReadEnabled();

    SEL sSet = NSSelectorFromString(@"setEnabled:");
    if (![core respondsToSelector:sSet]) return;
    IMP impSet = [core methodForSelector:sSet];
    if (!impSet) return;

    // (a) plist 与 _enabled 不一致 → 调源码 setEnabled: (走源码 enable/disable 分支)
    if (cur != plistEn) {
        ((void(*)(id,SEL,BOOL))impSet)(core, sSet, plistEn);
        VcamFix_Log([NSString stringWithFormat:@"[vcam][fix] setEnabled:%d", (int)plistEn]);
        return;
    }

    // (b) plist=YES、_enabled=YES 但 _prerenderActive=NO → 源码的 startPrerenderThread
    if (plistEn && cur) {
        Ivar ivPre = class_getInstanceVariable(cls, "_prerenderActive");
        BOOL pre = ivPre ? *(BOOL *)(base + ivar_getOffset(ivPre)) : NO;
        if (!pre) {
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
        }
    }
}

#pragma mark - 1. 诊断 (打 VCamCore 全部关键状态)

static void VcamFix_Diag(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) {
        VcamFix_DiagLine([NSString stringWithFormat:@"[%@] DIAG: VCamCore NOT FOUND\n", [NSDate date]]);
        return;
    }
    id core = VcamFix_CoreInstance();
    if (!core) {
        VcamFix_DiagLine([NSString stringWithFormat:@"[%@] DIAG: core nil\n", [NSDate date]]);
        return;
    }

    uint8_t *base = (uint8_t *)(__bridge void *)core;
    Ivar ivMd   = class_getInstanceVariable(cls, "_isMediaserverdProcess");
    Ivar ivEn   = class_getInstanceVariable(cls, "_enabled");
    Ivar ivG    = class_getInstanceVariable(cls, "_licGate");
    Ivar ivM    = class_getInstanceVariable(cls, "_licMark");
    Ivar ivPre  = class_getInstanceVariable(cls, "_prerenderActive");
    Ivar ivLive = class_getInstanceVariable(cls, "_liveYUVPixelBuffer");
    Ivar ivIdle = class_getInstanceVariable(cls, "_pipelineIdle");

    BOOL isMd = ivMd   ? *(BOOL *)(base + ivar_getOffset(ivMd))   : NO;
    BOOL en   = ivEn   ? *(BOOL *)(base + ivar_getOffset(ivEn))   : NO;
    BOOL lic  = ivG    ? *(BOOL *)(base + ivar_getOffset(ivG))    : NO;
    BOOL mk   = ivM    ? *(BOOL *)(base + ivar_getOffset(ivM))    : NO;
    BOOL pre  = ivPre  ? *(BOOL *)(base + ivar_getOffset(ivPre))  : NO;
    BOOL idle = ivIdle ? *(BOOL *)(base + ivar_getOffset(ivIdle)) : NO;
    CVPixelBufferRef live = ivLive ? *(CVPixelBufferRef *)(base + ivar_getOffset(ivLive)) : NULL;

    id player = nil;
    @try { player = [core valueForKey:@"videoPlayer"]; } @catch (...) {}
    uint64_t fc = 0;
    BOOL paused = NO;
    NSInteger mtype = 0;
    NSString *path = @"(nil)";
    NSUInteger qcount = 0;
    if (player) {
        Ivar ivFc = class_getInstanceVariable([player class], "_frameCount");
        if (!ivFc) ivFc = class_getInstanceVariable([player class], "frameCount");
        if (ivFc) fc = *(uint64_t *)((uint8_t *)(__bridge void *)player + ivar_getOffset(ivFc));
        @try { paused = [[player valueForKey:@"paused"] boolValue]; } @catch (...) {}
        @try { mtype = [[player valueForKey:@"mediaType"] integerValue]; } @catch (...) {}
        @try { path = [player valueForKey:@"currentVideoPath"]; } @catch (...) {}
        id q = nil;
        @try { q = [player valueForKey:@"frameQueue"]; } @catch (...) {}
        if (q) { @try { qcount = [[q valueForKey:@"count"] unsignedIntegerValue]; } @catch (...) {} }
    }

    BOOL pEn = NO;
    NSString *pPath = @"(nil)";
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
        if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
        if (d) {
            pEn = [d[@"enabled"] boolValue];
            pPath = d[@"activePlaybackPath"] ?: @"(nil)";
        }
    } @catch (...) {}

    BOOL fEx = NO;
    unsigned long long fSz = 0;
    if (path && ![path isEqualToString:@"(nil)"] && path.length > 0) {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (attr) { fEx = YES; fSz = [attr fileSize]; }
    }

    NSString *line = [NSString stringWithFormat:
        @"[%@] isMd=%d en=%d lic=%d mk=%d pre=%d idle=%d live=%s | plist.en=%d path=%@ | fc=%llu paused=%d mtype=%ld path=%@ fex=%d fsz=%llu | q=%lu\n",
        [NSDate date], isMd, en, lic, mk, pre, idle, live ? "YES" : "nil",
        pEn, pPath, fc, paused, (long)mtype, path ?: @"(nil)", fEx, fSz,
        (unsigned long)qcount];
    VcamFix_DiagLine(line);
}

#pragma mark - 2. controlTabTapped (照搬源码 VCamFloatingBall.controlTabTapped)

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

    UIView *controlPage = nil;
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    UIView *panelView = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    UIButton *ctrlBtn = nil;
    @try { ctrlBtn = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    if (!controlPage || !panelView) return;

    controlPage.hidden = NO;
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;

    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = active;
    UIButton *actBtn = [panelView viewWithTag:0x56435041];
    if (actBtn) actBtn.backgroundColor = inactive;

    // 源码 applyPanelContentHeight: 的等价实现
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
        VcamFix_Log(@"[vcam][fix] controlTab addTarget OK");
    }
}

#pragma mark - 3. VCamHidePatch.hideBall / showBall (照搬源码, 加类名 fallback)

static void VcamFix_hideBall(Class self, SEL _cmd) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @YES;
        [d writeToFile:@"/var/mobile/Media/DCIM/vc.plist" atomically:YES];
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
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @NO;
        [d writeToFile:@"/var/mobile/Media/DCIM/vc.plist" atomically:YES];
    } @catch (...) {}

    id ball = VcamFix_BallInstance();
    if (!ball) return;
    @try {
        UIView *bv = [ball valueForKey:@"ballView"];
        if (bv) bv.hidden = NO;
    } @catch (...) {}
}

#pragma mark - 4. VCamHidePatch.pollForPanelAndInjectButton (照搬源码, hideBtn 放末行下方)

static void VcamFix_pollForPanelAndInjectButton(Class self, SEL _cmd) {
    static BOOL injected = NO;
    if (injected) return;

    id ball = VcamFix_BallInstance();
    if (!ball) return;

    UIView *cpv = nil;
    @try { cpv = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    if (!cpv) return;

    NSInteger kTag = 0x56434D31;
    if ([cpv viewWithTag:kTag]) { injected = YES; return; }

    // 找末行底部 (不覆盖 + 按钮)
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
    hb.tag = kTag;
    hb.frame = CGRectMake(pad, maxBottom + 8, cw, cellH);
    hb.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
    hb.layer.cornerRadius = 9;
    hb.layer.masksToBounds = YES;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
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

    // 回调 = VCamHidePatch.vchp_hideTapped (源码里已存在)
    [hb addTarget:self action:NSSelectorFromString(@"vchp_hideTapped")
        forControlEvents:UIControlEventTouchUpInside];
    [cpv addSubview:hb];

    // 扩高控制页 + 面板 (照搬源码 poll 里 vchp 的语义)
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
        if ([ball respondsToSelector:s]) {
            ((void(*)(id,SEL))[ball methodForSelector:s])(ball, s);
        }
    }

    injected = YES;
    VcamFix_Log(@"[vcam][fix] hideBtn injected (末行下方)");
}

#pragma mark - 5. VCamActionPatch.actionTabTapped (照搬源码, 去掉 lightPage 判空)

static void VcamFix_actionTabTapped(id self, SEL _cmd) {
    id ball = VcamFix_BallInstance();
    if (!ball) return;

    UIView *panelView = nil, *controlPage = nil;
    UIButton *controlTab = nil;
    @try { panelView   = [ball valueForKey:@"panelView"]; }       @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    @try { controlTab  = [ball valueForKey:@"tabControlBtn"]; }   @catch (...) {}
    if (!panelView || !controlPage) return;

    UIView *actionPage = [panelView viewWithTag:0x56435042];
    UIButton *actionTab = [panelView viewWithTag:0x56435041];
    if (!actionPage || !actionTab) return;

    controlPage.hidden = YES;
    actionPage.hidden = NO;

    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (controlTab) controlTab.backgroundColor = inactive;
    actionTab.backgroundColor = active;

    SEL s1 = NSSelectorFromString(@"refreshStatus");
    if ([self respondsToSelector:s1]) ((void(*)(id,SEL))[self methodForSelector:s1])(self, s1);
    SEL s2 = NSSelectorFromString(@"refreshDuration");
    if ([self respondsToSelector:s2]) ((void(*)(id,SEL))[self methodForSelector:s2])(self, s2);

    CGFloat targetH = actionPage.frame.origin.y + actionPage.frame.size.height + 10;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = panelView.frame;
        f.size.height = targetH;
        panelView.frame = f;
    }];
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
            // 1) swizzle render 入口 (刷 _licGate/_licMark)
            Class coreCls = VcamFix_CoreClass();
            if (coreCls) {
                Method mr = class_getInstanceMethod(coreCls,
                    NSSelectorFromString(@"renderReplacementToPixelBuffer:pts:"));
                if (mr) {
                    gOrig_render = (void (*)(id,SEL,CVPixelBufferRef,double))method_getImplementation(mr);
                    method_setImplementation(mr, (IMP)VcamFix_render);
                    VcamFix_Log(@"[vcam][fix] render swizzled");
                }
            }

            // 2) timer: 0.1s 主动同步 plist.enabled → setEnabled:
            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            gTimerMD = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerMD,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                (uint64_t)(0.1 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerMD, ^{
                @autoreleasepool { VcamFix_SyncEnabled(); }
            });
            dispatch_resume(gTimerMD);

            // 3) diag: 立即一行 + 每 0.5s
            VcamFix_Diag();
            gTimerDiag = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerDiag,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerDiag, ^{
                @autoreleasepool { VcamFix_Diag(); }
            });
            dispatch_resume(gTimerDiag);

            VcamFix_Log(@"[vcam][fix] md init done");

        } else if (isSB) {
            // 5) swizzle VCamActionPatch.actionTabTapped (去掉 lightPage 判空)
            Class actCls = NSClassFromString(@"VCamActionPatch");
            if (actCls) {
                Method m = class_getInstanceMethod(actCls, NSSelectorFromString(@"actionTabTapped"));
                if (m) {
                    method_setImplementation(m, (IMP)VcamFix_actionTabTapped);
                    VcamFix_Log(@"[vcam][fix] actionTabTapped swizzled");
                }
            }

            // 3) swizzle VCamHidePatch.hideBall / showBall (类名 fallback)
            Class hideCls = NSClassFromString(@"VCamHidePatch");
            if (hideCls) {
                Method m1 = class_getClassMethod(hideCls, NSSelectorFromString(@"hideBall"));
                if (m1) {
                    method_setImplementation(m1, (IMP)VcamFix_hideBall);
                    VcamFix_Log(@"[vcam][fix] hideBall swizzled");
                }
                Method m2 = class_getClassMethod(hideCls, NSSelectorFromString(@"showBall"));
                if (m2) {
                    method_setImplementation(m2, (IMP)VcamFix_showBall);
                    VcamFix_Log(@"[vcam][fix] showBall swizzled");
                }
                // 4) swizzle VCamHidePatch.pollForPanelAndInjectButton (hideBtn 位置)
                Method m3 = class_getClassMethod(hideCls, NSSelectorFromString(@"pollForPanelAndInjectButton"));
                if (m3) {
                    method_setImplementation(m3, (IMP)VcamFix_pollForPanelAndInjectButton);
                    VcamFix_Log(@"[vcam][fix] pollHide swizzled");
                }
            }

            // 2) controlTabBtn 追加 target (照搬源码 controlTabTapped)
            dispatch_queue_t q = dispatch_get_main_queue();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), q, ^{
                VcamFix_EnsureControlTabTarget();
            });
            gTimerSB = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerSB,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerSB, ^{
                @autoreleasepool { VcamFix_EnsureControlTabTarget(); }
            });
            dispatch_resume(gTimerSB);

            VcamFix_Log(@"[vcam][fix] sb init done");
        }
    }
}
