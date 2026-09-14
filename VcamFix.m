//
//  VcamFix.m — 对精简版源码的运行时补丁（源码零更改）
//
//  修复:
//  1. 视频静止不播放 —— polling 因 _licMark=NO 把 setEnabled:NO 覆盖, 预渲染线程
//     退出且 _prerenderActive 卡 YES, 再也起不来。swizzle setEnabled: 拦截与
//     plist 不一致的调用, 让源码 setEnabled: 分支只在 plist 真值下执行
//  2. 点 + 键面板消失 / 隐藏按钮失效 —— VCamHidePatch 把 hideBtn 覆盖到 + 按钮
//     位置, 且找不到类名。swizzle VCamHidePatch.pollForPanelAndInjectButton 为
//     空实现阻止它注入, 本补丁自己注入 hideBtn 到独立行
//  3. 功能按钮缺失 —— 补 复/←↑→↓/镜/▶ (只补完整版原有按钮, 无自造功能)
//  4. 动作按钮 —— VCamActionPatch 已有完整逻辑, 本补丁仅在未注入时兜底
//
//  用法: 在 Makefile 的 VcamMax_FILES 里追加 VcamFix.m 即可
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <unistd.h>
#import "VCamNotify.h"

#pragma mark - 文件级保活

static dispatch_source_t gVcamFixUITimer      = nil;
static dispatch_source_t gVcamFixEnabledTimer = nil;

#pragma mark - Tag 常量

static const NSInteger kTagHideBtn     = 0x56434D31;   // 与 VCamHidePatch 一致
static const NSInteger kTagActionTab   = 0x56435041;
static const NSInteger kTagActionPage  = 0x56435042;
static const NSInteger kTagFuncBtnBase = 0x46583000;

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

#pragma mark - swizzle: setEnabled 参数与 plist 不一致时拦截

static void (*gOrig_setEnabled)(id, SEL, BOOL) = NULL;

static void VcamFix_setEnabled(id self, SEL _cmd, BOOL enabled) {
    BOOL plistEn = VcamFix_ReadPlistEnabled();
    if (enabled != plistEn) {
        VcamFix_Log([NSString stringWithFormat:
            @"[vcam][fix] setEnabled:%d BLOCKED (plist=%d)", enabled, plistEn]);
        return;
    }
    if (gOrig_setEnabled) gOrig_setEnabled(self, _cmd, enabled);
}

#pragma mark - 0.1s timer: plist 与 _enabled 差异 -> 调 setEnabled: 同步

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
    if (![core respondsToSelector:sSet]) return;
    IMP imp = [core methodForSelector:sSet];
    if (!imp) return;
    ((void (*)(id, SEL, BOOL))imp)(core, sSet, plistEn);
    VcamFix_Log([NSString stringWithFormat:
        @"[vcam][fix] enabled sync %d -> %d", cur, plistEn]);
}

#pragma mark - swizzle: VCamHidePatch.pollForPanelAndInjectButton -> 空

static void VcamFix_pollHideStub(id self, SEL _cmd) {
    // 空实现: 阻止 VCamHidePatch 把 hideBtn 覆盖到 "+" 按钮位置
}

#pragma mark - 控制页 target 桥

@interface VcamFixCtrlTarget : NSObject
+ (instancetype)shared;
- (void)onControlTabTapped:(id)sender;
- (void)onActionTabTapped:(id)sender;
- (void)onHideTapped:(id)sender;
- (void)onResetTransformTapped:(id)sender;
- (void)onPanUpTapped:(id)sender;
- (void)onPanDownTapped:(id)sender;
- (void)onPanLeftTapped:(id)sender;
- (void)onPanRightTapped:(id)sender;
- (void)onMirrorTapped:(id)sender;
- (void)onPlayPauseTapped:(id)sender;
- (void)onBlinkTapped:(id)sender;
- (void)onMouthTapped:(id)sender;
- (void)onHeadTapped:(id)sender;
- (void)onBlinkTimeTapped:(id)sender;
- (void)onMouthTimeTapped:(id)sender;
- (void)onHeadTimeTapped:(id)sender;
- (void)onResetAllTapped:(id)sender;
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

- (void)onHideTapped:(id)sender {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @YES;
        [d writeToFile:VcamFix_PlistPath() atomically:YES];
    } @catch (...) {}
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
    Class hideCls = NSClassFromString(@"VCamHidePatch");
    if (hideCls) {
        SEL sAct = NSSelectorFromString(@"activateThreeFingerWindow");
        if ([hideCls respondsToSelector:sAct]) {
            ((void(*)(id,SEL))[hideCls methodForSelector:sAct])(hideCls, sAct);
        }
    }
    VcamFix_Log(@"[vcam][fix] hide button tapped");
}

- (void)onResetTransformTapped:(id)sender {
    [VCamNotify resetPlistTransform];
    VcamFix_Log(@"[vcam][fix] btn 复");
}
- (void)onPanUpTapped:(id)sender {
    double ny = [VCamNotify plistPanY] - 0.05; if (ny < -1.0) ny = -1.0;
    [VCamNotify setPlistPanY:ny];
}
- (void)onPanDownTapped:(id)sender {
    double ny = [VCamNotify plistPanY] + 0.05; if (ny > 1.0) ny = 1.0;
    [VCamNotify setPlistPanY:ny];
}
- (void)onPanLeftTapped:(id)sender {
    double nx = [VCamNotify plistPanX] - 0.05; if (nx < -1.0) nx = -1.0;
    [VCamNotify setPlistPanX:nx];
}
- (void)onPanRightTapped:(id)sender {
    double nx = [VCamNotify plistPanX] + 0.05; if (nx > 1.0) nx = 1.0;
    [VCamNotify setPlistPanX:nx];
}
- (void)onMirrorTapped:(id)sender {
    BOOL m = ![VCamNotify plistMirrored];
    [VCamNotify setPlistMirrored:m];
}
- (void)onPlayPauseTapped:(id)sender {
    BOOL p = ![VCamNotify plistPaused];
    [VCamNotify setPlistPaused:p];
}

- (void)doAction:(int)action {
    Class cls = NSClassFromString(@"VCamActionPatch");
    if (cls) {
        SEL sShared = NSSelectorFromString(@"shared");
        if ([cls respondsToSelector:sShared]) {
            IMP imp = [cls methodForSelector:sShared];
            if (imp) {
                id inst = ((id(*)(id,SEL))imp)(cls, sShared);
                SEL sDo = NSSelectorFromString(@"doAction:");
                if (inst && [inst respondsToSelector:sDo]) {
                    ((void(*)(id,SEL,int))[inst methodForSelector:sDo])(inst, sDo, action);
                    VcamFix_Log([NSString stringWithFormat:@"[vcam][fix] action %d", action]);
                    return;
                }
            }
        }
    }
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        int tk = [d[@"actionToken"] intValue] + 1;
        d[@"actionToken"]  = @(tk);
        d[@"actionActive"] = @(action);
        [d writeToFile:VcamFix_PlistPath() atomically:YES];
        VcamFix_Log([NSString stringWithFormat:@"[vcam][fix] action %d token=%d", action, tk]);
    } @catch (...) {}
}

- (void)onBlinkTapped:(id)sender { [self doAction:1]; }
- (void)onMouthTapped:(id)sender { [self doAction:2]; }
- (void)onHeadTapped:(id)sender  { [self doAction:3]; }

- (void)callActionPatchTimeEdit:(NSString *)methodName {
    Class cls = NSClassFromString(@"VCamActionPatch");
    if (!cls) return;
    SEL sShared = NSSelectorFromString(@"shared");
    if (![cls respondsToSelector:sShared]) return;
    IMP imp = [cls methodForSelector:sShared];
    if (!imp) return;
    id inst = ((id(*)(id,SEL))imp)(cls, sShared);
    SEL s = NSSelectorFromString(methodName);
    if (inst && [inst respondsToSelector:s]) {
        ((void(*)(id,SEL))[inst methodForSelector:s])(inst, s);
    }
}
- (void)onBlinkTimeTapped:(id)sender { [self callActionPatchTimeEdit:@"blinkTimeTapped"]; }
- (void)onMouthTimeTapped:(id)sender { [self callActionPatchTimeEdit:@"mouthTimeTapped"]; }
- (void)onHeadTimeTapped:(id)sender  { [self callActionPatchTimeEdit:@"headTimeTapped"];  }

- (void)onResetAllTapped:(id)sender {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"actionBlinkStart"] = @1.0; d[@"actionBlinkEnd"] = @2.0;
        d[@"actionMouthStart"] = @2.5; d[@"actionMouthEnd"] = @3.5;
        d[@"actionHeadStart"]  = @4.0; d[@"actionHeadEnd"]  = @5.5;
        d[@"actionActive"] = @0;
        d[@"actionToken"]  = @([d[@"actionToken"] intValue] + 1);
        [d writeToFile:VcamFix_PlistPath() atomically:YES];
        VcamFix_Log(@"[vcam][fix] action reset all");
    } @catch (...) {}
}

@end

#pragma mark - 按钮工厂

static UIButton *VcamFix_MakeBtn(NSString *title, CGRect frame, NSInteger tag,
                                  SEL sel, CGFloat fontSize) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:fontSize];
    b.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
    b.layer.cornerRadius = 9;
    b.layer.masksToBounds = YES;
    [b addTarget:[VcamFixCtrlTarget shared] action:sel
        forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 调源码 updatePanelPosition（改 panelView 高度后重定位）

static void VcamFix_CallUpdatePanelPosition(id ball) {
    if (!ball) return;
    SEL s = NSSelectorFromString(@"updatePanelPosition");
    if (![ball respondsToSelector:s]) return;
    IMP imp = [ball methodForSelector:s];
    if (!imp) return;
    ((void(*)(id,SEL))imp)(ball, s);
}

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
    CGFloat colGap = 8;
    CGFloat colW3 = (contentW - colGap * 2) / 3.0;
    CGFloat cellH = 52;
    CGFloat gap = 8;
    CGFloat tabW = ctrlBtn.frame.size.width;
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

    // ===== 2. 功能按钮 (复/←↑→↓/镜/▶) =====
    if ([controlPage viewWithTag:kTagFuncBtnBase] == nil) {
        CGFloat baseY = 158;
        CGFloat y4 = baseY + gap;
        CGFloat y5 = y4 + cellH + gap;
        CGFloat y6 = y5 + cellH + gap;

        [controlPage addSubview:VcamFix_MakeBtn(@"←",
            CGRectMake(pad, y4, colW3, cellH), kTagFuncBtnBase + 1,
            @selector(onPanLeftTapped:), 20)];
        [controlPage addSubview:VcamFix_MakeBtn(@"↑",
            CGRectMake(pad + colW3 + colGap, y4, colW3, cellH), kTagFuncBtnBase + 2,
            @selector(onPanUpTapped:), 20)];
        [controlPage addSubview:VcamFix_MakeBtn(@"→",
            CGRectMake(pad + (colW3 + colGap) * 2, y4, colW3, cellH), kTagFuncBtnBase + 3,
            @selector(onPanRightTapped:), 20)];
        [controlPage addSubview:VcamFix_MakeBtn(@"↓",
            CGRectMake(pad, y5, colW3, cellH), kTagFuncBtnBase + 4,
            @selector(onPanDownTapped:), 20)];
        [controlPage addSubview:VcamFix_MakeBtn(@"▶",
            CGRectMake(pad + colW3 + colGap, y5, colW3, cellH), kTagFuncBtnBase + 5,
            @selector(onPlayPauseTapped:), 20)];
        [controlPage addSubview:VcamFix_MakeBtn(@"镜",
            CGRectMake(pad + (colW3 + colGap) * 2, y5, colW3, cellH), kTagFuncBtnBase + 6,
            @selector(onMirrorTapped:), 20)];
        [controlPage addSubview:VcamFix_MakeBtn(@"复",
            CGRectMake(pad, y6, contentW, cellH), kTagFuncBtnBase + 7,
            @selector(onResetTransformTapped:), 18)];

        controlPage.frame = CGRectMake(controlPage.frame.origin.x,
                                       controlPage.frame.origin.y,
                                       controlPage.frame.size.width,
                                       y6 + cellH);   // 338
        panelView.frame = CGRectMake(panelView.frame.origin.x,
                                     panelView.frame.origin.y,
                                     panelView.frame.size.width,
                                     pageTop + 338 + pad);
        VcamFix_CallUpdatePanelPosition(ball);
        VcamFix_Log(@"[vcam][fix] functional buttons injected");
    }

    // 刷新 ▶/⏸
    UIButton *playBtn = (UIButton *)[controlPage viewWithTag:kTagFuncBtnBase + 5];
    if (playBtn) {
        BOOL paused = [VCamNotify plistPaused];
        NSString *want = paused ? @"▶" : @"⏸";
        if (![[playBtn titleForState:UIControlStateNormal] isEqualToString:want]) {
            [playBtn setTitle:want forState:UIControlStateNormal];
        }
    }

    // ===== 3. 隐藏按钮 (独立行, 位于功能按钮之后) =====
    if (![controlPage viewWithTag:kTagHideBtn]) {
        CGFloat hideY = 338 + gap;   // 346
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
                                       346 + 34);   // 380
        panelView.frame = CGRectMake(panelView.frame.origin.x,
                                     panelView.frame.origin.y,
                                     panelView.frame.size.width,
                                     pageTop + 380 + pad);
        VcamFix_CallUpdatePanelPosition(ball);
        VcamFix_Log(@"[vcam][fix] hide button injected");
    }

    // ===== 4. 动作 tab + 动作页 (VCamActionPatch 未注入时兜底) =====
    if (![panelView viewWithTag:kTagActionTab]) {
        CGFloat totalW = tabW * 2 + 6;
        CGFloat x0 = (panelW - totalW) / 2;
        ctrlBtn.frame = CGRectMake(x0, tabY, tabW, tabH);

        UIButton *actionTab = [UIButton buttonWithType:UIButtonTypeSystem];
        actionTab.tag = kTagActionTab;
        actionTab.frame = CGRectMake(x0 + tabW + 6, tabY, tabW, tabH);
        [actionTab setTitle:@"动作" forState:UIControlStateNormal];
        actionTab.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        actionTab.layer.cornerRadius = 7;
        actionTab.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
        [actionTab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [actionTab addTarget:[VcamFixCtrlTarget shared]
                      action:@selector(onActionTabTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [panelView addSubview:actionTab];

        UIView *actionPage = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, 240)];
        actionPage.tag = kTagActionPage;
        actionPage.backgroundColor = [UIColor clearColor];
        actionPage.hidden = YES;

        CGFloat actionBtnH = 56;
        NSArray *titles = @[@"眨", @"嘴", @"头"];
        SEL sels[3] = { @selector(onBlinkTapped:), @selector(onMouthTapped:), @selector(onHeadTapped:) };
        for (int i = 0; i < 3; i++) {
            [actionPage addSubview:VcamFix_MakeBtn(titles[i],
                CGRectMake(pad + (colW3 + colGap) * i, 0, colW3, actionBtnH),
                0x56435050 + i, sels[i], 22)];
        }

        CGFloat timeY = actionBtnH + 10;
        CGFloat timeBtnH = 36;
        NSArray *tt = @[@"眨时间", @"嘴时间", @"头时间"];
        SEL ts[3] = { @selector(onBlinkTimeTapped:), @selector(onMouthTimeTapped:), @selector(onHeadTimeTapped:) };
        for (int i = 0; i < 3; i++) {
            UIButton *t = VcamFix_MakeBtn(tt[i],
                CGRectMake(pad + (colW3 + colGap) * i, timeY, colW3, timeBtnH),
                0x56435060 + i, ts[i], 13);
            t.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:1.0];
            [actionPage addSubview:t];
        }

        CGFloat resetY = timeY + timeBtnH + 10;
        UIButton *reset = VcamFix_MakeBtn(@"重置全部",
            CGRectMake(pad, resetY, contentW, 36),
            0x56435070, @selector(onResetAllTapped:), 13);
        reset.backgroundColor = [UIColor colorWithRed:0.55 green:0.30 blue:0.30 alpha:1.0];
        [actionPage addSubview:reset];

        CGRect pf = actionPage.frame;
        pf.size.height = resetY + 36;
        actionPage.frame = pf;

        [panelView addSubview:actionPage];
        VcamFix_Log(@"[vcam][fix] action tab + page injected");
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
                // 1) swizzle render 入口刷门禁
                SEL sRender = NSSelectorFromString(@"renderReplacementToPixelBuffer:pts:");
                Method mRender = class_getInstanceMethod(coreCls, sRender);
                if (mRender) {
                    gOrig_renderPts = (void (*)(id, SEL, CVPixelBufferRef, double))
                        method_getImplementation(mRender);
                    method_setImplementation(mRender, (IMP)VcamFix_renderPts);
                    VcamFix_Log(@"[vcam][fix] swizzled render OK");
                }
                // 2) swizzle setEnabled: 拦截与 plist 不一致的调用
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
            // swizzle VCamHidePatch.pollForPanelAndInjectButton -> 空
            // (防止它把 hideBtn 覆盖到 "+" 按钮位置)
            Class hideCls = NSClassFromString(@"VCamHidePatch");
            if (hideCls) {
                SEL sPoll = NSSelectorFromString(@"pollForPanelAndInjectButton");
                Method mPoll = class_getClassMethod(hideCls, sPoll);
                if (mPoll) {
                    method_setImplementation(mPoll, (IMP)VcamFix_pollHideStub);
                    VcamFix_Log(@"[vcam][fix] swizzled VCamHidePatch.pollForPanelAndInjectButton -> stub");
                }
            }

            dispatch_queue_t q = dispatch_get_main_queue();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           q, ^{ VcamFix_PatchUI(); });
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
