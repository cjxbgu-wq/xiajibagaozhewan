//
//  VcamFix.m — 照搬源码逻辑, 只 swizzle 精简版失效之处
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VCamNotify.h"

static dispatch_source_t gTimer = nil;

#pragma mark - 日志
static void VcamFix_Log(NSString *msg) {
    NSString *entry = [NSString stringWithFormat:@"[%@][fix] %@\n", [NSDate date], msg];
    NSArray *paths = @[@"/tmp/vcam_fix_log.txt", @"/var/mobile/Media/DCIM/vcam_fix_log.txt"];
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

static NSString *VcamFix_PlistPath(void) { return @"/var/mobile/Media/DCIM/vc.plist"; }
static BOOL VcamFix_ReadEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}

#pragma mark - swizzle render: 每帧刷门禁
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

#pragma mark - timer: 同步 plist.enabled -> VCamCore.setEnabled:
// (源码 polling 因 _licMark=NO 恒算 effEnabled=NO, setEnabled: 永远不调)
static void VcamFix_SyncEnabled(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;
    uint8_t *base = (uint8_t *)(__bridge void *)core;
    Ivar ivMd = class_getInstanceVariable(cls, "_isMediaserverdProcess");
    if (!ivMd) return;
    if (!*(BOOL *)(base + ivar_getOffset(ivMd))) return;

    Ivar ivG = class_getInstanceVariable(cls, "_licGate");
    Ivar ivM = class_getInstanceVariable(cls, "_licMark");
    if (ivG) *(BOOL *)(base + ivar_getOffset(ivG)) = YES;
    if (ivM) *(BOOL *)(base + ivar_getOffset(ivM)) = YES;

    Ivar ivEn = class_getInstanceVariable(cls, "_enabled");
    if (!ivEn) return;
    BOOL cur = *(BOOL *)(base + ivar_getOffset(ivEn));
    BOOL plistEn = VcamFix_ReadEnabled();
    if (cur == plistEn) return;

    SEL s = NSSelectorFromString(@"setEnabled:");
    if (![core respondsToSelector:s]) return;
    IMP imp = [core methodForSelector:s];
    if (!imp) return;
    ((void(*)(id,SEL,BOOL))imp)(core, s, plistEn);
    VcamFix_Log([NSString stringWithFormat:@"[vcam][fix] setEnabled:%d", (int)plistEn]);
}

#pragma mark - swizzle VCamActionPatch.actionTabTapped (照搬完整版逻辑, 去掉 lightPage 检查)
static void VcamFix_actionTabTapped(id self, SEL _cmd) {
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIView *panelView = nil, *controlPage = nil;
    UIButton *controlTab = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    @try { controlTab = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
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

    // 刷新状态标签 (源码 VCamActionPatch 的方法)
    SEL s1 = NSSelectorFromString(@"refreshStatus");
    if ([self respondsToSelector:s1]) ((void(*)(id,SEL))[self methodForSelector:s1])(self, s1);
    SEL s2 = NSSelectorFromString(@"refreshDuration");
    if ([self respondsToSelector:s2]) ((void(*)(id,SEL))[self methodForSelector:s2])(self, s2);

    // 面板高度扩到 action 页底部
    CGFloat pageTop = actionPage.frame.origin.y;
    CGFloat contentH = actionPage.frame.size.height;
    CGFloat targetH = pageTop + contentH + 10;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = panelView.frame;
        f.size.height = targetH;
        panelView.frame = f;
    }];
}

#pragma mark - 控制页 target 桥 (等价源码 VCamFloatingBall.controlTabTapped)
@interface VcamFixCtrlTarget : NSObject
+ (instancetype)shared;
- (void)onControlTabTapped:(id)sender;
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
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    @try { ctrlBtn = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    if (!panelView || !controlPage) return;

    controlPage.hidden = NO;
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;

    UIButton *actBtn = [panelView viewWithTag:0x56435041];
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = active;
    if (actBtn)  actBtn.backgroundColor  = inactive;

    // 恢复 panelView 高度 (等价源码 applyPanelContentHeight:)
    CGFloat targetH = controlPage.frame.origin.y + controlPage.frame.size.height + 10;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = panelView.frame;
        f.size.height = targetH;
        panelView.frame = f;
    }];
}
@end

#pragma mark - VCamHidePatch 三处 (照搬源码, 只加类名 fallback)
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

    // 找末行底部 (不覆盖 −/+)
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

#pragma mark - 只禁用不启用
static void VcamFix_toggleReplacement(id self, SEL _cmd) {
    if ([VCamNotify isPlistEnabled]) {
        [VCamNotify setPlistEnabled:NO];
        id core = VcamFix_CoreInstance();
        if (core) {
            SEL s = NSSelectorFromString(@"setEnabled:");
            if ([core respondsToSelector:s]) {
                IMP imp = [core methodForSelector:s];
                if (imp) ((void(*)(id,SEL,BOOL))imp)(core, s, NO);
            }
        }
        VcamFix_Log(@"[vcam][fix] toggle: disabled");
    } else {
        VcamFix_Log(@"[vcam][fix] toggle: noop");
    }
    SEL s = NSSelectorFromString(@"updateReplaceButtonVisual");
    if ([self respondsToSelector:s]) ((void(*)(id,SEL))[self methodForSelector:s])(self, s);
}

static void VcamFix_updateReplaceButtonVisual(id self, SEL _cmd) {
    BOOL en = [VCamNotify isPlistEnabled];
    id btn = nil;
    @try { btn = [self valueForKey:@"replaceBtn"]; } @catch (...) {}
    if (!btn) return;
    [(UIButton *)btn setTitle:@"禁用视频" forState:UIControlStateNormal];
    ((UIView *)btn).layer.borderWidth = 2;
    ((UIView *)btn).layer.borderColor = en
        ? [UIColor colorWithRed:0.30 green:0.85 blue:0.45 alpha:1.0].CGColor
        : [UIColor clearColor].CGColor;
}

#pragma mark - 给 tabControlBtn 追加 target (轮询式, panelView 就绪后)
static void VcamFix_ensureControlTabTarget(void) {
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
                    action:@selector(onControlTabTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        VcamFix_Log(@"[vcam][fix] controlTab addTarget OK");
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
            Class coreCls = VcamFix_CoreClass();
            if (coreCls) {
                Method mr = class_getInstanceMethod(coreCls, NSSelectorFromString(@"renderReplacementToPixelBuffer:pts:"));
                if (mr) {
                    gOrig_render = (void (*)(id,SEL,CVPixelBufferRef,double))method_getImplementation(mr);
                    method_setImplementation(mr, (IMP)VcamFix_render);
                }
            }
            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                (uint64_t)(0.1 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimer, ^{
                @autoreleasepool { VcamFix_SyncEnabled(); }
            });
            dispatch_resume(gTimer);
            VcamFix_Log(@"[vcam][fix] md init");

        } else if (isSB) {
            // 只禁用不启用 + 标题固定
            Class ballCls = VcamFix_BallClass();
            if (ballCls) {
                Method mt = class_getInstanceMethod(ballCls, NSSelectorFromString(@"toggleReplacementTapped"));
                if (mt) method_setImplementation(mt, (IMP)VcamFix_toggleReplacement);
                Method mu = class_getInstanceMethod(ballCls, NSSelectorFromString(@"updateReplaceButtonVisual"));
                if (mu) method_setImplementation(mu, (IMP)VcamFix_updateReplaceButtonVisual);
            }
            // 动作 tab 切换 (照搬完整版逻辑)
            Class actCls = NSClassFromString(@"VCamActionPatch");
            if (actCls) {
                Method m = class_getInstanceMethod(actCls, NSSelectorFromString(@"actionTabTapped"));
                if (m) method_setImplementation(m, (IMP)VcamFix_actionTabTapped);
            }
            // VCamHidePatch
            Class hideCls = NSClassFromString(@"VCamHidePatch");
            if (hideCls) {
                Method m1 = class_getClassMethod(hideCls, NSSelectorFromString(@"hideBall"));
                if (m1) method_setImplementation(m1, (IMP)VcamFix_hideBall);
                Method m2 = class_getClassMethod(hideCls, NSSelectorFromString(@"showBall"));
                if (m2) method_setImplementation(m2, (IMP)VcamFix_showBall);
                Method m3 = class_getClassMethod(hideCls, NSSelectorFromString(@"pollForPanelAndInjectButton"));
                if (m3) method_setImplementation(m3, (IMP)VcamFix_pollHide);
            }
            // tabControlBtn 追加 target
            dispatch_queue_t q = dispatch_get_main_queue();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), q, ^{
                VcamFix_ensureControlTabTarget();
            });
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                      (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(t, ^{
                @autoreleasepool { VcamFix_ensureControlTabTarget(); }
            });
            dispatch_resume(t);
            static dispatch_source_t sKeep = nil; sKeep = t;
            VcamFix_Log(@"[vcam][fix] sb init");
        }
    }
}
