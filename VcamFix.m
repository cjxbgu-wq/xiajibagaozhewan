//
//  VcamFix.m
//  对精简版源码的运行时补丁（源码零更改）
//
//  修复:
//  1. UI 控制页面打不开 —— tabControlBtn 未绑 target, 补 target + 补"返回控制"按钮
//  2. 悬浮球隐藏按钮注入 —— VCamHidePatch 只找 Jx6, 补 VCamFloatingBall fallback
//  3. 真实镜头与替换闪烁 —— 精简版 vcamSelfIntegrityOK 恒 NO, polling 把 _licMark
//     置 NO → setEnabled:NO → 替换被拒。本补丁 swizzle renderReplacementToPixelBuffer:
//     pts: 每次渲染前强制 _licGate/_licMark = YES, 彻底绕开门禁
//  4. 禁用替换关不掉 —— 上一版补丁强置 _enabled=YES 覆盖了禁用。本版改为 swizzle
//     setEnabled: 参数强制用 plist 的 enabled, 并 0.1s 定时同步, 使禁用/启用正常
//
//  用法: 在 Makefile 的 VcamMax_FILES 里追加 VcamFix.m 即可
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <unistd.h>

#pragma mark - 文件级保活

static dispatch_source_t gVcamFixUITimer      = nil;
static dispatch_source_t gVcamFixEnabledTimer = nil;

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

#pragma mark - 类名兼容 (支持混淆 / 未混淆)

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

#pragma mark - plist 读 enabled

static BOOL VcamFix_ReadPlistEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                           @"/var/mobile/Media/DCIM/vc.plist"];
        if (!d) d = [NSDictionary dictionaryWithContentsOfFile:
                     @"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}

#pragma mark - 核心 swizzle: render 前强制门禁 YES

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

#pragma mark - 核心 swizzle: setEnabled 参数强制用 plist 值

static void (*gOrig_setEnabled)(id, SEL, BOOL) = NULL;

static void VcamFix_setEnabled(id self, SEL _cmd, BOOL enabled) {
    // polling 会因 _licMark=NO 传 NO, 强制改成 plist 的当前值
    BOOL plistEn = VcamFix_ReadPlistEnabled();
    if (gOrig_setEnabled) gOrig_setEnabled(self, _cmd, plistEn);
}

#pragma mark - enabled 同步 timer (0.1s)

static void VcamFix_SyncEnabled(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;

    Ivar ivEn = class_getInstanceVariable(cls, "_enabled");
    if (!ivEn) return;
    uint8_t *base = (uint8_t *)(__bridge void *)core;
    BOOL cur = *(BOOL *)(base + ivar_getOffset(ivEn));
    BOOL plistEn = VcamFix_ReadPlistEnabled();
    if (cur == plistEn) return;

    SEL sSet = NSSelectorFromString(@"setEnabled:");
    if ([core respondsToSelector:sSet]) {
        ((void (*)(id, SEL, BOOL))[core methodForSelector:sSet])(core, sSet, plistEn);
        VcamFix_Log([NSString stringWithFormat:
            @"[vcam][fix] enabled sync %d -> %d (plist)", cur, plistEn]);
    }
}

#pragma mark - 控制页 target 桥

@interface VcamFixCtrlTarget : NSObject
+ (instancetype)shared;
- (void)onControlTabTapped:(id)sender;
- (void)onActionExitTapped:(id)sender;
- (void)onHideTapped:(id)sender;
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
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;

    UIButton *actBtn = [panelView viewWithTag:0x56435041];
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = active;
    if (actBtn)  actBtn.backgroundColor  = inactive;
}

- (void)onActionExitTapped:(id)sender {
    [self onControlTabTapped:sender];
}

- (void)onHideTapped:(id)sender {
    Class hideCls = NSClassFromString(@"VCamHidePatch");
    if (!hideCls) {
        VcamFix_Log(@"[vcam][fix] VCamHidePatch not found, hide noop");
        return;
    }
    SEL sHide = NSSelectorFromString(@"hideBall");
    SEL sAct  = NSSelectorFromString(@"activateThreeFingerWindow");
    if ([hideCls respondsToSelector:sHide]) {
        ((void(*)(id,SEL))[hideCls methodForSelector:sHide])(hideCls, sHide);
    }
    if ([hideCls respondsToSelector:sAct]) {
        ((void(*)(id,SEL))[hideCls methodForSelector:sAct])(hideCls, sAct);
    }
}

@end

#pragma mark - UI 补丁 (SpringBoard)

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

    // 补 1: tabControlBtn 追加 target
    BOOL hasCtrlTarget = NO;
    for (id t in [ctrlBtn allTargets]) {
        if ([t isKindOfClass:[VcamFixCtrlTarget class]]) { hasCtrlTarget = YES; break; }
    }
    if (!hasCtrlTarget) {
        [ctrlBtn addTarget:[VcamFixCtrlTarget shared]
                    action:@selector(onControlTabTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        VcamFix_Log(@"[vcam][fix] tabControlBtn addTarget(controlTabTapped) OK");
    }

    // 补 2: 动作页"返回控制"按钮
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage && ![actionPage viewWithTag:0x46465843]) {
        CGRect f = actionPage.frame;
        UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
        back.tag = 0x46465843;
        back.frame = CGRectMake(10, f.size.height - 42, f.size.width - 20, 36);
        [back setTitle:@"返回控制" forState:UIControlStateNormal];
        [back setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        back.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        back.backgroundColor = [UIColor colorWithRed:0.36 green:0.42 blue:0.58 alpha:1.0];
        back.layer.cornerRadius = 6;
        back.layer.masksToBounds = YES;
        [back addTarget:[VcamFixCtrlTarget shared]
                 action:@selector(onActionExitTapped:)
       forControlEvents:UIControlEventTouchUpInside];
        [actionPage addSubview:back];
        f.size.height += 46;
        actionPage.frame = f;
        VcamFix_Log(@"[vcam][fix] action page back button injected");
    }

    // 补 3: 隐藏按钮
    if (![controlPage viewWithTag:0x56434D31]) {
        CGFloat maxX = -1, maxY = -1, cellW = 0, cellH = 0;
        for (UIView *sub in controlPage.subviews) {
            if (![sub isKindOfClass:[UIButton class]]) continue;
            CGRect f = sub.frame;
            if (f.origin.x > maxX) maxX = f.origin.x;
            if (f.origin.y > maxY) { maxY = f.origin.y; cellW = f.size.width; cellH = f.size.height; }
        }
        if (maxX >= 0 && maxY >= 0 && cellW > 0 && cellH > 0) {
            UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            hideBtn.tag = 0x56434D31;
            hideBtn.frame = CGRectMake(maxX, maxY, cellW, cellH);
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
            VcamFix_Log([NSString stringWithFormat:
                @"[vcam][fix] hide button injected at (%.1f,%.1f) size %.1fx%.1f",
                maxX, maxY, cellW, cellH]);
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
            if (!coreCls) {
                VcamFix_Log(@"[vcam][fix] VCamCore class NOT FOUND");
            } else {
                // 1) swizzle renderReplacementToPixelBuffer:pts:
                SEL sRender = NSSelectorFromString(@"renderReplacementToPixelBuffer:pts:");
                Method mRender = class_getInstanceMethod(coreCls, sRender);
                if (mRender) {
                    gOrig_renderPts = (void (*)(id, SEL, CVPixelBufferRef, double))
                        method_getImplementation(mRender);
                    method_setImplementation(mRender, (IMP)VcamFix_renderPts);
                    VcamFix_Log(@"[vcam][fix] swizzled renderReplacementToPixelBuffer:pts: OK");
                } else {
                    VcamFix_Log(@"[vcam][fix] render method NOT FOUND");
                }

                // 2) swizzle setEnabled:
                SEL sSet = NSSelectorFromString(@"setEnabled:");
                Method mSet = class_getInstanceMethod(coreCls, sSet);
                if (mSet) {
                    gOrig_setEnabled = (void (*)(id, SEL, BOOL))method_getImplementation(mSet);
                    method_setImplementation(mSet, (IMP)VcamFix_setEnabled);
                    VcamFix_Log(@"[vcam][fix] swizzled setEnabled: OK");
                } else {
                    VcamFix_Log(@"[vcam][fix] setEnabled: NOT FOUND");
                }
            }

            // 3) 0.1s timer 同步 _enabled 与 plist
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), q, ^{
                VcamFix_PatchUI();
            });
            gVcamFixUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gVcamFixUITimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                (uint64_t)(1.0 * NSEC_PER_SEC),
                (uint64_t)(0.2 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gVcamFixUITimer, ^{
                @autoreleasepool { VcamFix_PatchUI(); }
            });
            dispatch_resume(gVcamFixUITimer);
        }
    }
}
