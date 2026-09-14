//
//  VcamFix.m
//  照搬源码逻辑, 只 swizzle 精简版失效/缺失的几处
//  不新增任何 UI 按钮
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VCamNotify.h"

static dispatch_source_t gVcamFixGateTimer = nil;

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

#pragma mark - 类名兼容 (照搬源码 VCamActionPatch.m 的 Jx6 ?: VCamFloatingBall)

static Class VcamFix_BallClass(void) {
    Class c = NSClassFromString(@"Jx6");
    if (c) return c;
    return NSClassFromString(@"VCamFloatingBall");
}
static id VcamFix_BallInstance(void) {
    Class c = VcamFix_BallClass();
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    IMP f = [c methodForSelector:s];
    if (!f) return nil;
    return ((id(*)(id,SEL))f)(c, s);
}
static Class VcamFix_CoreClass(void) {
    Class c = NSClassFromString(@"Qz1");
    if (c) return c;
    return NSClassFromString(@"VCamCore");
}
static id VcamFix_CoreInstance(void) {
    Class c = VcamFix_CoreClass();
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    IMP f = [c methodForSelector:s];
    if (!f) return nil;
    return ((id(*)(id,SEL))f)(c, s);
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

#pragma mark - 核心修复: swizzle VCamCore.setEnabled: 用 plist 真值调 orig

static void (*gOrig_setEnabled)(id, SEL, BOOL) = NULL;

static void VcamFix_setEnabled(id self, SEL _cmd, BOOL enabled) {
    // polling 因 _licMark=NO 恒传 NO; 忽略入参, 一律用 plist 真值走源码分支
    BOOL plistEn = VcamFix_ReadEnabled();
    if (gOrig_setEnabled) gOrig_setEnabled(self, _cmd, plistEn);
}

#pragma mark - render 入口刷门禁 (防 polling 中途翻转导致 _licMark=NO)

static void (*gOrig_renderPts)(id, SEL, CVPixelBufferRef, double) = NULL;

static void VcamFix_renderPts(id self, SEL _cmd, CVPixelBufferRef pb, double pts) {
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
    if (gOrig_renderPts) gOrig_renderPts(self, _cmd, pb, pts);
}

#pragma mark - 用户需求: 只禁用不启用 (照搬源码 toggleReplacementTapped 的禁用分支)

static void VcamFix_toggleReplacement(id self, SEL _cmd) {
    if ([VCamNotify isPlistEnabled]) {
        [VCamNotify setPlistEnabled:NO];
        [[VCamCore sharedInstance] setEnabled:NO];
        VcamFix_Log(@"[vcam][fix] toggle: disabled -> real camera");
    } else {
        // 已禁用状态下点按钮: 无操作 (启用唯一路径 = 选视频)
        VcamFix_Log(@"[vcam][fix] toggle: already disabled, noop (use 选择视频 to enable)");
    }
    SEL s = NSSelectorFromString(@"updateReplaceButtonVisual");
    if ([self respondsToSelector:s]) {
        ((void(*)(id,SEL))[self methodForSelector:s])(self, s);
    }
}

#pragma mark - 用户需求: 按钮标题永远"禁用视频" (照搬源码 updateReplaceButtonVisual 的边框逻辑)

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

#pragma mark - VCamHidePatch 三指呼出 (照搬源码 hideBall/showBall, 只加类名 fallback)

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

#pragma mark - hideBtn 位置 (照搬源码位置算法, 精简版布局下放末行下方)

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
    [hb addTarget:self action:NSSelectorFromString(@"vchp_hideTapped")
        forControlEvents:UIControlEventTouchUpInside];
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
                    gOrig_renderPts = (void (*)(id,SEL,CVPixelBufferRef,double))method_getImplementation(mr);
                    method_setImplementation(mr, (IMP)VcamFix_renderPts);
                }
                Method ms = class_getInstanceMethod(coreCls, NSSelectorFromString(@"setEnabled:"));
                if (ms) {
                    gOrig_setEnabled = (void (*)(id,SEL,BOOL))method_getImplementation(ms);
                    method_setImplementation(ms, (IMP)VcamFix_setEnabled);
                }
            }
            VcamFix_Log(@"[vcam][fix] md: setEnabled swizzled (plist 真值)");

        } else if (isSB) {
            // VCamFloatingBall: 只禁用 + 标题固定
            Class ballCls = VcamFix_BallClass();
            if (ballCls) {
                Method mt = class_getInstanceMethod(ballCls, NSSelectorFromString(@"toggleReplacementTapped"));
                if (mt) method_setImplementation(mt, (IMP)VcamFix_toggleReplacement);
                Method mu = class_getInstanceMethod(ballCls, NSSelectorFromString(@"updateReplaceButtonVisual"));
                if (mu) method_setImplementation(mu, (IMP)VcamFix_updateReplaceButtonVisual);
            }

            // VCamHidePatch: 三指呼出 + hideBtn
            Class hideCls = NSClassFromString(@"VCamHidePatch");
            if (hideCls) {
                Method m1 = class_getClassMethod(hideCls, NSSelectorFromString(@"hideBall"));
                if (m1) method_setImplementation(m1, (IMP)VcamFix_hideBall);
                Method m2 = class_getClassMethod(hideCls, NSSelectorFromString(@"showBall"));
                if (m2) method_setImplementation(m2, (IMP)VcamFix_showBall);
                Method m3 = class_getClassMethod(hideCls, NSSelectorFromString(@"pollForPanelAndInjectButton"));
                if (m3) method_setImplementation(m3, (IMP)VcamFix_pollHide);
            }

            // SpringBoard 里也 swizzle setEnabled (SpringBoard 的 VCamCore 是 lean 版, 只写 _enabled)
            Class coreCls = VcamFix_CoreClass();
            if (coreCls) {
                Method ms = class_getInstanceMethod(coreCls, NSSelectorFromString(@"setEnabled:"));
                if (ms) {
                    if (!gOrig_setEnabled) {
                        gOrig_setEnabled = (void (*)(id,SEL,BOOL))method_getImplementation(ms);
                    }
                    method_setImplementation(ms, (IMP)VcamFix_setEnabled);
                }
            }
            VcamFix_Log(@"[vcam][fix] sb: toggle/updateBtn/hidePatch swizzled");
        }
    }
}
