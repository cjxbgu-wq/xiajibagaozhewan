//
//  VcamFix.m
//  照搬完整版源码逻辑, 只 swizzle 精简版失效的 3 处
//  不创建任何新 UI
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 文件级保活
static dispatch_source_t gVcamFixGateTimer = nil;

#pragma mark - 类名兼容 (与源码 VCamActionPatch.m 同款 fallback)

static Class VcamFix_BallClass(void) {
    Class cls = NSClassFromString(@"Jx6");
    if (cls) return cls;
    return NSClassFromString(@"VCamFloatingBall");
}

static id VcamFix_BallInstance(void) {
    Class cls = VcamFix_BallClass();
    if (!cls) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:s]) return nil;
    IMP imp = [cls methodForSelector:s];
    if (!imp) return nil;
    return ((id(*)(id,SEL))imp)(cls, s);
}

// plist 路径 (对齐源码 VCHP_PlistPath 的解码结果)
static NSString *VcamFix_PlistPath(void) {
    return @"/var/mobile/Media/DCIM/vc.plist";
}

#pragma mark - 漏洞 1: mediaserverd 侧让 _licMark 兜底 (照搬源码的 vcamSelfTextOK 语义)

// 源码 vcamSelfTextOK 在 __vcsig 全 0 (开发构建) 时直接返回 YES。
// 精简版删了 vcamSelfTextOK, 导致 _licMark 只靠 vcamSelfIntegrityOK 单点。
// 本函数每 0.1s 把 _licMark 强制 YES —— 语义等同源码"vcamSelfTextOK 兜底成功"。
static void VcamFix_ForceMark(void) {
    Class cls = NSClassFromString(@"Qz1");
    if (!cls) cls = NSClassFromString(@"VCamCore");
    if (!cls) return;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:s]) return;
    IMP imp = [cls methodForSelector:s];
    if (!imp) return;
    id core = ((id(*)(id,SEL))imp)(cls, s);
    if (!core) return;

    uint8_t *base = (uint8_t *)(__bridge void *)core;
    Ivar ivG = class_getInstanceVariable(cls, "_licGate");
    Ivar ivM = class_getInstanceVariable(cls, "_licMark");
    if (ivG) *(BOOL *)(base + ivar_getOffset(ivG)) = YES;
    if (ivM) *(BOOL *)(base + ivar_getOffset(ivM)) = YES;
}

#pragma mark - 漏洞 2: VCamHidePatch.hideBall (照搬源码, 类名兼容)

static void VcamFix_hideBall(Class self, SEL _cmd) {
    // 对齐源码 VCHP_SetBallHidden(YES)
    @try {
        NSString *path = VcamFix_PlistPath();
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @YES;
        [d writeToFile:path atomically:YES];
    } @catch (...) {}

    id ball = VcamFix_BallInstance();
    if (!ball) return;
    @try {
        UIView *ballView  = [ball valueForKey:@"ballView"];
        UIView *panelView = [ball valueForKey:@"panelView"];
        if (ballView)  ballView.hidden  = YES;
        if (panelView) panelView.hidden = YES;
        [ball setValue:@NO forKey:@"panelVisible"];
    } @catch (...) {}
}

#pragma mark - 漏洞 2: VCamHidePatch.showBall (照搬源码, 类名兼容)

static void VcamFix_showBall(Class self, SEL _cmd) {
    @try {
        NSString *path = VcamFix_PlistPath();
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"ballHidden"] = @NO;
        [d writeToFile:path atomically:YES];
    } @catch (...) {}

    id ball = VcamFix_BallInstance();
    if (!ball) return;
    @try {
        UIView *ballView = [ball valueForKey:@"ballView"];
        if (ballView) ballView.hidden = NO;
    } @catch (...) {}
}

#pragma mark - 漏洞 3: VCamHidePatch.pollForPanelAndInjectButton
//  照搬源码, 唯一区别: hideBtn 放到末行下方独立一行
//  (源码的 maxX/maxY 在完整版 4x3 网格落在空格; 精简版 3 行布局会覆盖 + 按钮)

static void VcamFix_pollForPanelAndInjectButton(Class self, SEL _cmd) {
    static BOOL gButtonInjected = NO;
    if (gButtonInjected) return;

    id ball = VcamFix_BallInstance();
    if (!ball) return;

    UIView *controlPageView = nil;
    @try { controlPageView = [ball valueForKey:@"controlPageView"]; } @catch (...) { return; }
    if (!controlPageView) return;

    NSInteger tag = 0x56434D31;
    if ([controlPageView viewWithTag:tag]) {
        gButtonInjected = YES;
        return;
    }

    // 找控制页里 y+h 最大的按钮 (末行), hideBtn 放它下面
    CGFloat maxBottom = -1;
    CGFloat cellH = 0;
    for (UIView *sub in controlPageView.subviews) {
        if (![sub isKindOfClass:[UIButton class]]) continue;
        CGRect f = sub.frame;
        CGFloat bottom = f.origin.y + f.size.height;
        if (bottom > maxBottom) {
            maxBottom = bottom;
            cellH = f.size.height;
        }
    }
    if (maxBottom < 0) return;

    CGFloat pad = 10;
    CGFloat contentW = controlPageView.frame.size.width - pad * 2;

    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.tag = tag;
    hideBtn.frame = CGRectMake(pad, maxBottom + 8, contentW, cellH);
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

    // 点击走源码 VCamHidePatch.vchp_hideTapped (self = VCamHidePatch 类对象)
    [hideBtn addTarget:self
                action:NSSelectorFromString(@"vchp_hideTapped")
      forControlEvents:UIControlEventTouchUpInside];
    [controlPageView addSubview:hideBtn];

    // 扩高控制页 + 面板 (对齐源码 applyPanelContentHeight 的语义)
    CGRect cf = controlPageView.frame;
    cf.size.height = maxBottom + 8 + cellH + 8;
    controlPageView.frame = cf;

    UIView *panelView = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    if (panelView) {
        CGRect pf = panelView.frame;
        pf.size.height = cf.origin.y + cf.size.height + 10;
        panelView.frame = pf;
        SEL s = NSSelectorFromString(@"updatePanelPosition");
        if ([ball respondsToSelector:s]) {
            ((void(*)(id,SEL))[ball methodForSelector:s])(ball, s);
        }
    }

    gButtonInjected = YES;
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
            // 漏洞 1: 让 _licMark 兜底 YES, 使源码 polling 的
            //         effEnabled = plist.enabled && _licGate && _licMark 走通
            VcamFix_ForceMark();
            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            gVcamFixGateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gVcamFixGateTimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                (uint64_t)(0.1 * NSEC_PER_SEC),
                (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gVcamFixGateTimer, ^{
                @autoreleasepool { VcamFix_ForceMark(); }
            });
            dispatch_resume(gVcamFixGateTimer);

        } else if (isSB) {
            // 漏洞 2 & 3: swizzle VCamHidePatch 三个类方法
            Class hideCls = NSClassFromString(@"VCamHidePatch");
            if (hideCls) {
                Method m1 = class_getClassMethod(hideCls, NSSelectorFromString(@"hideBall"));
                if (m1) method_setImplementation(m1, (IMP)VcamFix_hideBall);

                Method m2 = class_getClassMethod(hideCls, NSSelectorFromString(@"showBall"));
                if (m2) method_setImplementation(m2, (IMP)VcamFix_showBall);

                Method m3 = class_getClassMethod(hideCls, NSSelectorFromString(@"pollForPanelAndInjectButton"));
                if (m3) method_setImplementation(m3, (IMP)VcamFix_pollForPanelAndInjectButton);
            }
        }
    }
}
