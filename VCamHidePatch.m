//
//  VCamHidePatch.m
//  悬浮球隐藏/呼出补丁（三指长按 1.5s 呼出）
//
//  init 函数 vchp_init() 由 Tweak.m 显式调用
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void VCHP_Log(NSString *msg) {
    NSString *entry = [NSString stringWithFormat:@"[%@][hide] %@\n", [NSDate date], msg];
    NSArray *paths = @[@"/tmp/vcam_ball_log.txt", @"/var/mobile/Media/DCIM/vcam_ball_log.txt"];
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
        } @catch (NSException *e) {}
    }
}

// 字符串解码（XOR）
static NSString *VCHP_DecodeStr(const unsigned char *v) {
    unsigned char key = v[0];
    unsigned char buf[128];
    NSUInteger n = 0;
    while (v[n + 1] && n < sizeof(buf) - 1) { buf[n] = v[n + 1] ^ key; n++; }
    buf[n] = 0;
    return [NSString stringWithUTF8String:(const char *)buf];
}

// plist 路径（XOR 加密）
static NSString *VCHP_PlistPath(void) {
    static NSString *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const unsigned char enc[] = {
            0xA5,
            0x8A, 0xD3, 0xC4, 0xD7, 0x8A, 0xC8, 0xCA, 0xC7, 0xCC, 0xC9, 0xC0,
            0x8A, 0xE8, 0xC0, 0xC1, 0xCC, 0xC4, 0x8A, 0xE1, 0xE6, 0xEC, 0xE8,
            0x8A, 0xD3, 0xC6, 0x8B, 0xD5, 0xC9, 0xCC, 0xD6, 0xD1, 0x00
        };
        s = VCHP_DecodeStr(enc);
    });
    return s;
}

// ============================================================
//  常量
// ============================================================
static const NSInteger kHideButtonTag        = 0x56434D31;
static const CGFloat   kThreeFingerAreaRatio = 0.25;
static const CGFloat   kThreeFingerPressSecs = 1.5;
static const CGFloat   kThreeFingerMoveMax   = 200.0;
static const NSUInteger kThreeFingerCount    = 3;
static NSString *const kBallHiddenKey        = @"ballHidden";

// plist 读写
static void VCHP_SetBallHidden(BOOL hidden) {
    @try {
        NSString *path = VCHP_PlistPath();
        if (!path) return;
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!dict) dict = [NSMutableDictionary dictionary];
        dict[kBallHiddenKey] = @(hidden);
        [dict writeToFile:path atomically:YES];
    } @catch (NSException *e) {}
}

static BOOL VCHP_GetBallHidden(void) {
    @try {
        NSString *path = VCHP_PlistPath();
        if (!path) return NO;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        return [dict[kBallHiddenKey] boolValue];
    } @catch (NSException *e) { return NO; }
}

// 悬浮球实例查找（混淆类名 Jx6）
static Class VCHP_BallClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"Jx6"); });
    return cls;
}

static id VCHP_BallInstance(void) {
    Class cls = VCHP_BallClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    IMP imp = [cls methodForSelector:sel];
    if (!imp) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
    return fn(cls, sel);
}

// ============================================================
//  三指手势专用 window（顶部 75% 区域命中，下方 25% 穿透）
// ============================================================
@interface VCamThreeFingerWindow : UIWindow
@end
@implementation VCamThreeFingerWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat areaTop = self.bounds.size.height * (1.0 - kThreeFingerAreaRatio);
    if (point.y < areaTop) return nil;
    return [super hitTest:point withEvent:event];
}
@end

// ============================================================
//  VCamHidePatch
// ============================================================
@interface VCamHidePatch : NSObject <UIGestureRecognizerDelegate>
+ (void)install;
+ (void)activateThreeFingerWindow;
+ (void)deactivateThreeFingerWindow;
+ (void)hideBall;
+ (void)showBall;
+ (void)applyHiddenStateIfNeeded;
+ (void)pollForPanelAndInjectButton;
@end

@implementation VCamHidePatch

static UIWindow *gThreeFingerWindow = nil;
static BOOL      gInstalled         = NO;
static BOOL      gButtonInjected    = NO;
static BOOL      gHiddenApplied     = NO;
static CFAbsoluteTime gLastDiag     = 0;
static dispatch_source_t gKeepTimer __attribute__((unused)) = nil;

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;
    VCHP_Log(@"hide install start");

    [self setupThreeFingerWindow];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
        (uint64_t)(0.5 * NSEC_PER_SEC),
        (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        [self pollForPanelAndInjectButton];
        [self applyHiddenStateIfNeeded];
    });
    dispatch_resume(timer);
    gKeepTimer = timer;

    if (VCHP_GetBallHidden()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self hideBall];
            [self activateThreeFingerWindow];
        });
    }
}

+ (void)pollForPanelAndInjectButton {
    if (gButtonInjected) return;
    id ball = VCHP_BallInstance();
    if (!ball) return;

    UIView *controlPageView = nil;
    @try { controlPageView = [ball valueForKey:@"controlPageView"]; } @catch (...) { return; }
    if (!controlPageView) return;

    if ([controlPageView viewWithTag:kHideButtonTag]) {
        gButtonInjected = YES;
        return;
    }

    // 找右下角位置（复用控制页最后一个按钮的坐标）
    CGFloat maxX = -1;
    CGFloat maxY = -1;
    CGFloat cellW = 0;
    CGFloat cellH = 0;
    for (UIView *sub in controlPageView.subviews) {
        if (![sub isKindOfClass:[UIButton class]]) continue;
        CGRect f = sub.frame;
        if (f.origin.x > maxX) maxX = f.origin.x;
        if (f.origin.y > maxY) {
            maxY = f.origin.y;
            cellW = f.size.width;
            cellH = f.size.height;
        }
    }
    if (maxX < 0 || maxY < 0 || cellW <= 0 || cellH <= 0) return;

    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.tag = kHideButtonTag;
    hideBtn.frame = CGRectMake(maxX, maxY, cellW, cellH);
    hideBtn.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
    hideBtn.layer.cornerRadius = 9;
    hideBtn.layer.masksToBounds = YES;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *sym = [UIImage imageNamed:@"eye.slash.fill" inBundle:nil compatibleWithTraitCollection:nil];
    if (!sym) {
        sym = [UIImage systemImageNamed:@"eye.slash.fill" withConfiguration:cfg];
    }
    if (sym) {
        [hideBtn setImage:sym forState:UIControlStateNormal];
        hideBtn.tintColor = [UIColor whiteColor];
        hideBtn.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
    } else {
        [hideBtn setTitle:@"隐" forState:UIControlStateNormal];
        [hideBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        hideBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    }

    [hideBtn addTarget:self action:@selector(vchp_hideTapped)
      forControlEvents:UIControlEventTouchUpInside];
    [controlPageView addSubview:hideBtn];

    gButtonInjected = YES;
    VCHP_Log([NSString stringWithFormat:@"hide button injected at (%.1f,%.1f) size %.1fx%.1f",
              maxX, maxY, cellW, cellH]);
}

+ (void)vchp_hideTapped {
    VCHP_Log(@"hide button tapped");
    [self hideBall];
    [self activateThreeFingerWindow];
}

+ (void)hideBall {
    VCHP_SetBallHidden(YES);
    id ball = VCHP_BallInstance();
    if (!ball) return;
    @try {
        UIView *ballView  = [ball valueForKey:@"ballView"];
        UIView *panelView = [ball valueForKey:@"panelView"];
        if (ballView)  ballView.hidden  = YES;
        if (panelView) panelView.hidden = YES;
        [ball setValue:@NO forKey:@"panelVisible"];
    } @catch (NSException *e) {}
}

+ (void)showBall {
    VCHP_SetBallHidden(NO);
    id ball = VCHP_BallInstance();
    if (!ball) return;
    @try {
        UIView *ballView = [ball valueForKey:@"ballView"];
        if (ballView) ballView.hidden = NO;
    } @catch (NSException *e) {}
}

+ (void)applyHiddenStateIfNeeded {
    BOOL shouldHide = VCHP_GetBallHidden();
    if (shouldHide && !gHiddenApplied) {
        gHiddenApplied = YES;
        [self hideBall];
        [self activateThreeFingerWindow];
    } else if (!shouldHide && gHiddenApplied) {
        gHiddenApplied = NO;
        [self deactivateThreeFingerWindow];
    }
}

+ (void)setupThreeFingerWindow {
    if (gThreeFingerWindow) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) return;

    gThreeFingerWindow = [[VCamThreeFingerWindow alloc] initWithWindowScene:scene];
    gThreeFingerWindow.windowLevel = UIWindowLevelAlert + 1000;
    gThreeFingerWindow.backgroundColor = [UIColor clearColor];
    gThreeFingerWindow.hidden = YES;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = YES;
    gThreeFingerWindow.rootViewController = vc;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(vchp_threeFingerLongPress:)];
    lp.numberOfTouchesRequired = kThreeFingerCount;
    lp.minimumPressDuration = kThreeFingerPressSecs;
    lp.allowableMovement = kThreeFingerMoveMax;
    lp.cancelsTouchesInView = NO;
    lp.delegate = (id<UIGestureRecognizerDelegate>)self;
    [gThreeFingerWindow addGestureRecognizer:lp];
}

+ (void)activateThreeFingerWindow {
    if (!gThreeFingerWindow) [self setupThreeFingerWindow];
    if (!gThreeFingerWindow) return;
    gThreeFingerWindow.hidden = NO;
}

+ (void)deactivateThreeFingerWindow {
    if (gThreeFingerWindow) gThreeFingerWindow.hidden = YES;
}

+ (void)vchp_threeFingerLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    VCHP_Log(@"three-finger long press triggered");
    [self showBall];
    gHiddenApplied = NO;
    [self deactivateThreeFingerWindow];
}

+ (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end

// ============================================================
//  入口（由 Tweak.m 显式调用）
// ============================================================
void vchp_init(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *proc = [[[NSProcessInfo processInfo] processName] lowercaseString];
            if (![proc containsString:@"springboard"]) return;
            [VCamHidePatch install];
        });
    }
}
