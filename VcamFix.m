//
//  VcamFix.m — 对精简版源码的运行时补丁（源码零更改）
//
//  仅修复用户提出的 4 个问题:
//  1. 视频静止不播放
//  2. 点 + 键面板消失（hideBtn 覆盖在 + 上导致）
//  3. 隐藏按钮失效
//  4. 动作按钮失效
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
#import "VCamNotify.h"

#pragma mark - 文件级保活

static dispatch_source_t gVcamFixUITimer      = nil;
static dispatch_source_t gVcamFixEnabledTimer = nil;

#pragma mark - Tag 常量（与源码一致）

static const NSInteger kTagHideBtn    = 0x56434D31;
static const NSInteger kTagActionTab  = 0x56435041;
static const NSInteger kTagActionPage = 0x56435042;

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

#pragma mark - swizzle: setEnabled 与 plist 不一致时拦截

static void (*gOrig_setEnabled)(id, SEL, BOOL) = NULL;

static void VcamFix_setEnabled(id self, SEL _cmd, BOOL enabled) {
    BOOL plistEn = VcamFix_ReadPlistEnabled();
    if (enabled != plistEn) {
        // polling 因 _licMark=NO 恒传 NO, 拦截, 让 _enabled 只由 plist 决定
        return;
    }
    if (gOrig_setEnabled) gOrig_setEnabled(self, _cmd, enabled);
}

#pragma mark - 问题 1 核心: 0.1s timer 完整同步状态

static void VcamFix_SyncEnabled(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;

    uint8_t *base = (uint8_t *)(__bridge void *)core;

    // 修复: 未进入 mediaserverd 初始化前不操作, 否则 setEnabled 会走
    // "if (!_isMediaserverdProcess) { _enabled = enabled; return; }" 分支,
    // 导致 _enabled=YES 但 _prerenderActive=NO 卡死 (视频静止直接根因)
    Ivar ivMd = class_getInstanceVariable(cls, "_isMediaserverdProcess");
    if (ivMd) {
        BOOL isMd = *(BOOL *)(base + ivar_getOffset(ivMd));
        if (!isMd) return;  // 等下一拍
    } else {
        return;
    }

    Ivar ivEn = class_getInstanceVariable(cls, "_enabled");
    if (!ivEn) return;
    BOOL cur = *(BOOL *)(base + ivar_getOffset(ivEn));
    BOOL plistEn = VcamFix_ReadPlistEnabled();

    // (a) plist 与 _enabled 不一致 -> 走源码 setEnabled: 分支
    if (cur != plistEn) {
        SEL sSet = NSSelectorFromString(@"setEnabled:");
        if ([core respondsToSelector:sSet]) {
            IMP imp = [core methodForSelector:sSet];
            if (imp) {
                ((void (*)(id, SEL, BOOL))imp)(core, sSet, plistEn);
                VcamFix_Log([NSString stringWithFormat:
                    @"[vcam][fix] enabled sync %d -> %d", cur, plistEn]);
            }
        }
    }

    // (b) 兜底: _enabled=YES 但 _prerenderActive=NO -> 主动重启预渲染+解码
    //     (处理早期 timer 抢跑导致 setEnabled:YES 未启预渲染的卡死)
    if (plistEn) {
        Ivar ivPre = class_getInstanceVariable(cls, "_prerenderActive");
        if (ivPre) {
            BOOL pre = *(BOOL *)(base + ivar_getOffset(ivPre));
            BOOL en  = *(BOOL *)(base + ivar_getOffset(ivEn));
            if (en && !pre) {
                SEL sStart = NSSelectorFromString(@"startPrerenderThread");
                if ([core respondsToSelector:sStart]) {
                    ((void(*)(id,SEL))[core methodForSelector:sStart])(core, sStart);
                    VcamFix_Log(@"[vcam][fix] restart prerender thread (was dead)");
                }
                id player = nil;
                @try { player = [core valueForKey:@"videoPlayer"]; } @catch (...) {}
                if (player) {
                    SEL sDecode = NSSelectorFromString(@"startDecodingThread");
                    if ([player respondsToSelector:sDecode]) {
                        ((void(*)(id,SEL))[player methodForSelector:sDecode])(player, sDecode);
                        VcamFix_Log(@"[vcam][fix] restart decoding thread");
                    }
                }
            }
        }
    }
}

#pragma mark - 控制页 target 桥

@interface VcamFixCtrlTarget : NSObject
+ (instancetype)shared;
- (void)onControlTabTapped:(id)sender;
- (void)onActionTabTapped:(id)sender;
- (void)onHideTapped:(id)sender;
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

// 问题 3: 隐藏按钮逻辑 (对齐 VCamHidePatch.m 的 hideBall + activateThreeFingerWindow)
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

// 问题 4: 动作按钮逻辑 (优先调源码 VCamActionPatch.doAction:, 否则直写 plist)
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

#pragma mark - 调源码 updatePanelPosition（改 panelView.frame 后重定位）

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

    // ===== 2. 问题 2: 清理旧版 VcamFix 覆盖在 + 上的 hideBtn =====
    UIButton *oldHide = (UIButton *)[controlPage viewWithTag:kTagHideBtn];
    if (oldHide) {
        BOOL conflicts = NO;
        for (UIView *sub in controlPage.subviews) {
            if (sub == oldHide) continue;
            if (![sub isKindOfClass:[UIButton class]]) continue;
            if (CGRectIntersectsRect(sub.frame, oldHide.frame)) {
                conflicts = YES;
                break;
            }
        }
        if (conflicts) {
            [oldHide removeFromSuperview];
            VcamFix_Log(@"[vcam][fix] removed misplaced old hide button (overlapping +)");
        }
    }

    // ===== 3. 问题 3: 隐藏按钮 (独立行 y=166, 不覆盖 −/+) =====
    if (![controlPage viewWithTag:kTagHideBtn]) {
        CGFloat hideY = 158 + 8;   // 现有 3 行底部 = 158
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
        VcamFix_CallUpdatePanelPosition(ball);
        VcamFix_Log(@"[vcam][fix] hide button injected at y=166");
    }

    // ===== 4. 问题 4: 动作 tab + 动作页 =====
    UIButton *actTab = (UIButton *)[panelView viewWithTag:kTagActionTab];
    if (actTab) {
        // 已存在 (源码 VCamActionPatch 注入): 补充 target, 防源码 KVC 时序问题
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
    } else {
        // 未注入: 自己兜底注入
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
        VcamFix_Log(@"[vcam][fix] action tab + page injected (兜底)");
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
