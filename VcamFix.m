//
//  VcamFix.m
//  对精简版源码的运行时补丁（源码零更改）
//
//  修复项:
//  1. UI 控制页面无法打开 —— 精简版 VCamFloatingBall 未给 tabControlBtn 绑定
//     "显示控制页/隐藏动作页" 的 target, 面板卡在动作页。本补丁用 runtime 给
//     tabControlBtn 追加 TouchUpInside target, 并在动作页底部补一个"返回控制"按钮。
//
//  2. 核心逻辑替换失败 —— 精简版 VCamCore 保留了 _licGate / _licMark 门禁
//     (renderReplacementToPixelBuffer:pts: 会因此 return)。本补丁在
//     mediaserverd / lskdd 进程内以 0.5s 节拍强制保证 _licGate/_licMark/
//     _enabled 为 YES, 绕开门禁。
//
//  3. 悬浮球隐藏按钮注入 —— 精简版 VCamHidePatch 只找 Jx6(混淆名),
//     精简版无混淆时类名是 VCamFloatingBall 找不到。本补丁提供兼容查找,
//     若隐藏按钮标签缺失则主动注入。
//
//  用法: 在 Makefile 的 VcamMax_FILES 里追加 VcamFix.m 即可, 其它源码
//        一行都不用动。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <unistd.h>

#pragma mark - 文件级定时器保活

// 文件级 static: 强引用定时器, 防 ARC 释放, 且不会触发 unused-but-set 警告
static dispatch_source_t gVcamFixGateTimer = nil;
static dispatch_source_t gVcamFixUITimer   = nil;

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

#pragma mark - 悬浮球类名兼容查找（VCamHidePatch.m 缺的 fallback）

static Class VcamFix_BallClass(void) {
    Class cls = NSClassFromString(@"Jx6");
    if (cls) return cls;
    cls = NSClassFromString(@"VCamFloatingBall");
    return cls;
}

static id VcamFix_BallInstance(void) {
    Class cls = VcamFix_BallClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    IMP imp = [cls methodForSelector:sel];
    if (!imp) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
    return fn(cls, sel);
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

// 等价完整版 -[VCamFloatingBall controlTabTapped] 的效果
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

    // 对齐完整版 refreshTabStyles 的高亮: 控制 active / 动作 inactive
    UIButton *actBtn = [panelView viewWithTag:0x56435041];
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = active;
    if (actBtn)  actBtn.backgroundColor  = inactive;
}

- (void)onActionExitTapped:(id)sender {
    [self onControlTabTapped:sender];
}

// 隐藏按钮回调: 调用 VCamHidePatch 的类方法 hideBall / activateThreeFingerWindow
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
    VcamFix_Log(@"[vcam][fix] hide button tapped -> VCamHidePatch.hideBall");
}

@end

#pragma mark - UI 补丁主逻辑 (SpringBoard)

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

    // --- 补 1: tabControlBtn 追加 target (幂等) ---
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

    // --- 补 2: 动作页底部补"返回控制"按钮 (幂等) ---
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

    // --- 补 3: 隐藏按钮 (VCamHidePatch 只找 Jx6, 精简版类名是 VCamFloatingBall) ---
    // 完整版 VCamHidePatch.m 里用的 tag 是 0x56434D31
    if (![controlPage viewWithTag:0x56434D31]) {
        // 沿用 VCamHidePatch 的注入位置算法: 找控制页里 x 最大 / y 最大的按钮位置
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

#pragma mark - 门禁强制 (mediaserverd / lskdd)

static void VcamFix_ForceGate(void) {
    Class coreCls = NSClassFromString(@"Qz1");
    if (!coreCls) coreCls = NSClassFromString(@"VCamCore");
    if (!coreCls) return;

    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (![coreCls respondsToSelector:shared]) return;
    IMP imp = [coreCls methodForSelector:shared];
    if (!imp) return;
    id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
    id core = fn(coreCls, shared);
    if (!core) return;

    // KVC 路径 (属性名未改时)
    @try { [core setValue:@YES forKey:@"licGate"]; } @catch (...) {}
    @try { [core setValue:@YES forKey:@"licMark"]; } @catch (...) {}
    @try { [core setValue:@YES forKey:@"enabled"]; } @catch (...) {}

    // ivar 直写保险 (属性名若被改也不受影响; 精简版 ivar 名与完整版一致:
    // @property (nonatomic, assign) BOOL licGate; 合成 _licGate)
    Ivar ivGate = class_getInstanceVariable(coreCls, "_licGate");
    Ivar ivMark = class_getInstanceVariable(coreCls, "_licMark");
    Ivar ivEn   = class_getInstanceVariable(coreCls, "_enabled");
    uint8_t *base = (uint8_t *)(__bridge void *)core;
    if (ivGate) *(BOOL *)(base + ivar_getOffset(ivGate)) = YES;
    if (ivMark) *(BOOL *)(base + ivar_getOffset(ivMark)) = YES;
    if (ivEn)   *(BOOL *)(base + ivar_getOffset(ivEn))   = YES;
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
            // 立即一次 + 每 0.5s 一次, 防轮询翻转
            VcamFix_ForceGate();
            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            gVcamFixGateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gVcamFixGateTimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                (uint64_t)(0.5 * NSEC_PER_SEC),
                (uint64_t)(0.1 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gVcamFixGateTimer, ^{
                @autoreleasepool { VcamFix_ForceGate(); }
            });
            dispatch_resume(gVcamFixGateTimer);

        } else if (isSB) {
            // 等 VCamFloatingBall 的 overlayWindow 建好 (完整版约 1-2s)
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
