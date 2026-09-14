//
//  VCamActionPatch.m
//  动作页签注入（眨眼 / 嘴 / 头 三个动作按钮 + 时间设置）
//
//  架构：init 函数 vcap_init() 由 Tweak.m 显式调用（不用 constructor，避免被 -dead_strip 剥离）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#include <notify.h>

// 文件级 static 强引用（防 ARC 释放 timer）
static dispatch_source_t gActionPollTimer = nil;

// 动作通知名 XOR 编码（0x2E = "com.vcam.ios.action"）
static const unsigned char gActionNotifyEnc[] = {
    0x2E,
    0x4D, 0x41, 0x43, 0x50, 0x48, 0x4D, 0x41, 0x43, 0x48, 0x41, 0x43,
    0x4D, 0x4C, 0x46, 0x41, 0x4F, 0x46, 0x43, 0x4C, 0x4F, 0x4C, 0x4F,
    0x00
};

static void vcamActionNotifyPost(void) {
    unsigned char key = gActionNotifyEnc[0];
    char buf[64];
    size_t n = 0;
    while (gActionNotifyEnc[n + 1] && n < sizeof(buf) - 1) {
        buf[n] = gActionNotifyEnc[n + 1] ^ key;
        n++;
    }
    buf[n] = 0;
    notify_post(buf);
}

// ============================================================
//  日志
// ============================================================
static void VCAP_Log(NSString *msg) {
    NSString *entry = [NSString stringWithFormat:@"[%@][action] %@\n", [NSDate date], msg];
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

// ============================================================
//  字符串解码（XOR）
// ============================================================
static NSString *VCAP_DecodeStr(const unsigned char *v) {
    unsigned char key = v[0];
    unsigned char buf[128];
    NSUInteger n = 0;
    while (v[n + 1] && n < sizeof(buf) - 1) { buf[n] = v[n + 1] ^ key; n++; }
    buf[n] = 0;
    return [NSString stringWithUTF8String:(const char *)buf];
}

// plist 路径（XOR 加密 "/var/mobile/Media/DCIM/vc.plist"）
static NSString *VCAP_PlistPath(void) {
    static NSString *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const unsigned char enc[] = {
            0xA5,
            0x8A, 0xD3, 0xC4, 0xD7, 0x8A, 0xC8, 0xCA, 0xC7, 0xCC, 0xC9, 0xC0,
            0x8A, 0xE8, 0xC0, 0xC1, 0xCC, 0xC4, 0x8A, 0xE1, 0xE6, 0xEC, 0xE8,
            0x8A, 0xD3, 0xC6, 0x8B, 0xD5, 0xC9, 0xCC, 0xD6, 0xD1, 0x00
        };
        s = VCAP_DecodeStr(enc);
    });
    return s;
}

// ============================================================
//  plist 读写
// ============================================================
static double VCAP_GetDouble(NSString *key, double defVal) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VCAP_PlistPath()];
        NSNumber *v = d[key];
        return v ? [v doubleValue] : defVal;
    } @catch (...) { return defVal; }
}

static int VCAP_GetInt(NSString *key, int defVal) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VCAP_PlistPath()];
        NSNumber *v = d[key];
        return v ? [v intValue] : defVal;
    } @catch (...) { return defVal; }
}

static void VCAP_SetDict(NSDictionary *updates) {
    @try {
        NSString *p = VCAP_PlistPath();
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p];
        if (!d) d = [NSMutableDictionary dictionary];
        for (NSString *k in updates) d[k] = updates[k];
        [d writeToFile:p atomically:YES];
    } @catch (...) {}
}

// 动作 plist 键名
#define kBlinkStartKey @"actionBlinkStart"
#define kBlinkEndKey   @"actionBlinkEnd"
#define kMouthStartKey @"actionMouthStart"
#define kMouthEndKey   @"actionMouthEnd"
#define kHeadStartKey  @"actionHeadStart"
#define kHeadEndKey    @"actionHeadEnd"
#define kTokenKey      @"actionToken"
#define kActiveKey     @"actionActive"
#define kDurationKey   @"videoDuration"
#define kActionMaxSec  6.0

// ============================================================
//  悬浮球实例查找（兼容混淆名 Jx6 与未混淆名 VCamFloatingBall）
// ============================================================
static Class VCAP_FindBallClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = NSClassFromString(@"Jx6") ?: NSClassFromString(@"VCamFloatingBall");
    });
    return cls;
}

static id VCAP_FindBallInstance(void) {
    Class cls = VCAP_FindBallClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    IMP imp = [cls methodForSelector:sel];
    if (!imp) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
    return fn(cls, sel);
}

// ============================================================
//  VCamActionPatch
// ============================================================
@interface VCamActionPatch : NSObject
+ (instancetype)shared;
+ (void)install;
- (void)blinkTapped;
- (void)mouthTapped;
- (void)headTapped;
- (void)blinkTimeTapped;
- (void)mouthTimeTapped;
- (void)headTimeTapped;
- (void)actionTabTapped;
- (void)hideActionPageOnOtherTab;
- (void)resetAll;
- (void)pollTick;
- (void)ensureInjected;
@end

@implementation VCamActionPatch
{
    NSArray<UIButton *> *_actionBtns;
    NSArray<UIButton *> *_timeBtns;
    UILabel *_statusLabel;
    UILabel *_durationLabel;
    int _activeAction;
    BOOL _installed;
}

+ (instancetype)shared {
    static VCamActionPatch *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamActionPatch alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activeAction = 0;
        _installed = NO;
    }
    return self;
}

+ (void)install {
    VCamActionPatch *s = [VCamActionPatch shared];
    if (s->_installed) return;
    s->_installed = YES;
    VCAP_Log(@"action install start");

    gActionPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              dispatch_get_main_queue());
    if (!gActionPollTimer) {
        VCAP_Log(@"action install FAILED: dispatch_source_create returned nil");
        return;
    }
    dispatch_source_set_timer(gActionPollTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
        (uint64_t)(0.5 * NSEC_PER_SEC),
        (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gActionPollTimer, ^{
        [[VCamActionPatch shared] pollTick];
    });
    dispatch_resume(gActionPollTimer);

    VCAP_Log(@"action install done (timer retained)");
}

- (void)pollTick {
    [self ensureInjected];

    int token = VCAP_GetInt(kTokenKey, 0);
    static int lastToken = 0;
    if (token != lastToken) {
        lastToken = token;
        int active = VCAP_GetInt(kActiveKey, 0);
        if (active >= 1 && active <= 3) {
            _activeAction = active;
            [self highlightAction:active];
        } else {
            _activeAction = 0;
            [self highlightAction:0];
        }
    }
}

- (void)ensureInjected {
    Class ballCls = VCAP_FindBallClass();
    if (!ballCls) return;
    id ball = VCAP_FindBallInstance();
    if (!ball) return;

    UIView *panelView = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) { return; }
    if (!panelView) return;

    // 已注入
    if ([panelView viewWithTag:0x56435041]) return;

    VCAP_Log(@"action ensureInjected: injecting now");
    [self injectIntoBall:ball panelView:panelView];
}

- (void)injectIntoBall:(id)ball panelView:(UIView *)panelView {
    UIButton *controlTab = nil;
    UIButton *lightTab = nil;
    @try { controlTab = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    if (!controlTab) return;

    CGFloat panelW = panelView.frame.size.width;
    CGFloat tabW = controlTab.frame.size.width;
    CGFloat tabH = controlTab.frame.size.height;
    CGFloat tabY = controlTab.frame.origin.y;

    CGFloat tabGap = 6;
    CGFloat totalW = tabW * 2 + tabGap;
    CGFloat x0 = (panelW - totalW) / 2;
    controlTab.frame = CGRectMake(x0, tabY, tabW, tabH);

    // 动作 tab 按钮
    UIButton *actionTab = [UIButton buttonWithType:UIButtonTypeSystem];
    actionTab.tag = 0x56435041;
    actionTab.frame = CGRectMake(x0 + tabW + tabGap, tabY, tabW, tabH);
    [actionTab setTitle:@"动作" forState:UIControlStateNormal];
    actionTab.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    actionTab.layer.cornerRadius = 7;
    actionTab.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    [actionTab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [actionTab addTarget:[VCamActionPatch shared]
                  action:@selector(actionTabTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [panelView addSubview:actionTab];

    // 动作页
    UIView *page = [self buildActionPage:panelW tabControl:controlTab];
    page.tag = 0x56435042;
    page.hidden = YES;
    [panelView addSubview:page];

    // 切页联动
    if (controlTab) {
        [controlTab addTarget:self action:@selector(hideActionPageOnOtherTab)
             forControlEvents:UIControlEventTouchUpInside];
    }
    if (lightTab) {
        [lightTab addTarget:self action:@selector(hideActionPageOnOtherTab)
           forControlEvents:UIControlEventTouchUpInside];
    }

    VCAP_Log(@"action page injected");
}

- (void)hideActionPageOnOtherTab {
    id ball = VCAP_FindBallInstance();
    if (!ball) return;
    UIView *panelView = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    if (!panelView) return;
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;
}

- (UIView *)buildActionPage:(CGFloat)panelW tabControl:(UIButton *)tabControl {
    CGFloat pad = 10;
    CGFloat contentW = panelW - pad * 2;
    CGFloat pageTop = tabControl.frame.origin.y + tabControl.frame.size.height + 6;

    CGFloat labelH = 16;
    CGFloat actionBtnH = 56;
    CGFloat timeBtnH = 36;
    CGFloat gapY = 6;
    CGFloat statusH = 18;
    CGFloat bottomH = 28;
    CGFloat btnGap = 6;
    CGFloat btnW3 = (contentW - btnGap * 2) / 3.0;

    CGFloat pageH = labelH + gapY + actionBtnH + 10
                  + labelH + gapY + timeBtnH + 10
                  + statusH + 6 + bottomH;

    UIView *page = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, pageH)];
    page.backgroundColor = [UIColor clearColor];

    CGFloat y = 0;

    // 分组 1：动作按键
    UILabel *grp1 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, contentW, labelH)];
    grp1.text = @"动作按键";
    grp1.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    grp1.font = [UIFont systemFontOfSize:12];
    [page addSubview:grp1];
    y += labelH + gapY;

    NSMutableArray *ab = [NSMutableArray array];
    NSString *titles[3] = {@"眨", @"嘴", @"头"};
    SEL actions[3] = {@selector(blinkTapped), @selector(mouthTapped), @selector(headTapped)};
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(pad + (btnW3 + btnGap) * i, y, btnW3, actionBtnH);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        b.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
        b.layer.cornerRadius = 9;
        b.layer.masksToBounds = YES;
        [b addTarget:[VCamActionPatch shared] action:actions[i]
            forControlEvents:UIControlEventTouchUpInside];
        [page addSubview:b];
        [ab addObject:b];
    }
    _actionBtns = ab;
    y += actionBtnH + 10;

    // 分组 2：时间设置
    UILabel *grp2 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, contentW, labelH)];
    grp2.text = @"时间设置";
    grp2.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    grp2.font = [UIFont systemFontOfSize:12];
    [page addSubview:grp2];
    y += labelH + gapY;

    NSMutableArray *tb = [NSMutableArray array];
    NSString *titles2[3] = {@"眨时间", @"嘴时间", @"头时间"};
    SEL actions2[3] = {@selector(blinkTimeTapped), @selector(mouthTimeTapped), @selector(headTimeTapped)};
    for (int i = 0; i < 3; i++) {
        UIButton *t = [UIButton buttonWithType:UIButtonTypeSystem];
        t.frame = CGRectMake(pad + (btnW3 + btnGap) * i, y, btnW3, timeBtnH);
        [t setTitle:titles2[i] forState:UIControlStateNormal];
        [t setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        t.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        t.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:1.0];
        t.layer.cornerRadius = 7;
        t.layer.masksToBounds = YES;
        [t addTarget:[VCamActionPatch shared] action:actions2[i]
            forControlEvents:UIControlEventTouchUpInside];
        [page addSubview:t];
        [tb addObject:t];
    }
    _timeBtns = tb;
    y += timeBtnH + 10;

    // 状态行
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, contentW, statusH)];
    _statusLabel.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    _statusLabel.font = [UIFont systemFontOfSize:11];
    _statusLabel.adjustsFontSizeToFitWidth = YES;
    _statusLabel.minimumScaleFactor = 0.7;
    [page addSubview:_statusLabel];
    [self refreshStatus];
    y += statusH + 6;

    // 时长
    _durationLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y + 4, 130, 20)];
    _durationLabel.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    _durationLabel.font = [UIFont systemFontOfSize:12];
    [page addSubview:_durationLabel];
    [self refreshDuration];

    // 重置全部
    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(panelW - pad - 88, y, 88, bottomH);
    [resetBtn setTitle:@"重置全部" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    resetBtn.backgroundColor = [UIColor colorWithRed:0.55 green:0.30 blue:0.30 alpha:1.0];
    resetBtn.layer.cornerRadius = 6;
    resetBtn.layer.masksToBounds = YES;
    [resetBtn addTarget:[VCamActionPatch shared] action:@selector(resetAll)
        forControlEvents:UIControlEventTouchUpInside];
    [page addSubview:resetBtn];

    return page;
}

- (void)refreshStatus {
    if (!_statusLabel) return;
    double bs = VCAP_GetDouble(kBlinkStartKey, 1.0), be = VCAP_GetDouble(kBlinkEndKey, 2.0);
    double ms = VCAP_GetDouble(kMouthStartKey, 2.5), me = VCAP_GetDouble(kMouthEndKey, 3.5);
    double hs = VCAP_GetDouble(kHeadStartKey, 4.0),  he = VCAP_GetDouble(kHeadEndKey, 5.5);
    _statusLabel.text = [NSString stringWithFormat:
        @"眨 %.1f-%.1fs / 嘴 %.1f-%.1fs / 头 %.1f-%.1fs",
        bs, be, ms, me, hs, he];
}

- (void)refreshDuration {
    if (!_durationLabel) return;
    double dur = VCAP_GetDouble(kDurationKey, 0.0);
    _durationLabel.text = [NSString stringWithFormat:@"视频 %.2fs", dur];
}

- (void)actionTabTapped {
    id ball = VCAP_FindBallInstance();
    if (!ball) return;

    UIView *panelView = nil, *controlPage = nil, *lightPage = nil;
    UIButton *controlTab = nil, *lightTab = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    @try { lightPage = [ball valueForKey:@"lightPageView"]; } @catch (...) {}
    @try { controlTab = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    @try { lightTab = [ball valueForKey:@"tabLightBtn"]; } @catch (...) {}
    if (!panelView || !controlPage) return;

    UIView *actionPage = [panelView viewWithTag:0x56435042];
    UIButton *actionTab = [panelView viewWithTag:0x56435041];
    if (!actionPage || !actionTab) return;

    controlPage.hidden = YES;
    if (lightPage) lightPage.hidden = YES;
    actionPage.hidden = NO;

    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (controlTab) controlTab.backgroundColor = inactive;
    if (lightTab) lightTab.backgroundColor = inactive;
    actionTab.backgroundColor = active;

    [self refreshStatus];
    [self refreshDuration];

    // 面板高度自适应
    CGFloat pageTop = actionPage.frame.origin.y;
    CGFloat contentH = actionPage.frame.size.height;
    CGFloat targetH = pageTop + contentH + 10;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = panelView.frame;
        f.size.height = targetH;
        panelView.frame = f;
    }];
}

- (void)blinkTapped { [self doAction:1]; }
- (void)mouthTapped { [self doAction:2]; }
- (void)headTapped  { [self doAction:3]; }

- (void)doAction:(int)action {
    int tk = VCAP_GetInt(kTokenKey, 0) + 1;
    VCAP_SetDict(@{kTokenKey: @(tk), kActiveKey: @(action)});
    _activeAction = action;
    [self highlightAction:action];
    VCAP_Log([NSString stringWithFormat:@"do action %d (token=%d)", action, tk]);

    // 立即通知 md 侧
    vcamActionNotifyPost();

    // 1.5s 后自动取消高亮
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VCamActionPatch *s = weakSelf;
        if (!s) return;
        int curActive = VCAP_GetInt(kActiveKey, 0);
        if (curActive == action) {
            [s highlightAction:0];
        }
    });
}

- (void)highlightAction:(int)action {
    for (int i = 0; i < _actionBtns.count; i++) {
        UIButton *b = _actionBtns[i];
        if (i + 1 == action) {
            b.layer.borderWidth = 2.5;
            b.layer.borderColor = [UIColor whiteColor].CGColor;
        } else {
            b.layer.borderWidth = 0;
        }
    }
}

- (void)blinkTimeTapped { [self editTime:1]; }
- (void)mouthTimeTapped { [self editTime:2]; }
- (void)headTimeTapped  { [self editTime:3]; }

- (void)editTime:(int)which {
    NSString *name = @"";
    NSString *sk = @"";
    NSString *ek = @"";
    double defS = 0.0, defE = 0.0;

    if (which == 1) {
        name = @"眨"; sk = kBlinkStartKey; ek = kBlinkEndKey;
        defS = 1.0; defE = 2.0;
    } else if (which == 2) {
        name = @"嘴"; sk = kMouthStartKey; ek = kMouthEndKey;
        defS = 2.5; defE = 3.5;
    } else if (which == 3) {
        name = @"头"; sk = kHeadStartKey; ek = kHeadEndKey;
        defS = 4.0; defE = 5.5;
    } else {
        return;
    }

    double s = VCAP_GetDouble(sk, defS);
    double e = VCAP_GetDouble(ek, defE);
    double dur = VCAP_GetDouble(kDurationKey, 0.0);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"设置「%@」的时间段", name]
        message:[NSString stringWithFormat:
            @"视频时长 %.2fs · 单段上限 %.1fs", dur, kActionMaxSec]
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"起始(秒)";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", s];
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"结束(秒)";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", e];
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UITextField *tfS = alert.textFields[0];
            UITextField *tfE = alert.textFields[1];
            double ns = [tfS.text doubleValue];
            double ne = [tfE.text doubleValue];
            [weakSelf saveTimeStart:ns end:ne startKey:sk endKey:ek];
        }]];

    UIViewController *root = [self findRootVC];
    if (!root) return;
    [root presentViewController:alert animated:YES completion:nil];
}

- (UIViewController *)findRootVC {
    id ball = VCAP_FindBallInstance();
    if (ball) {
        UIWindow *win = nil;
        @try { win = [ball valueForKey:@"overlayWindow"]; } @catch (...) {}
        if (win && win.rootViewController) return win.rootViewController;
    }
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) return w.rootViewController;
            }
        }
    }
    return nil;
}

- (void)saveTimeStart:(double)s end:(double)e
             startKey:(NSString *)sk endKey:(NSString *)ek {
    double dur = VCAP_GetDouble(kDurationKey, 0.0);

    if (s < 0) { [self alertInvalid:@"起始时间不能为负"]; return; }
    if (e <= s) { [self alertInvalid:@"结束时间必须大于起始时间"]; return; }
    if ((e - s) > kActionMaxSec) {
        [self alertInvalid:[NSString stringWithFormat:
            @"单段时长 %.2fs 超过上限 %.1fs", e - s, kActionMaxSec]];
        return;
    }
    if (dur > 0 && e > dur) {
        [self alertInvalid:[NSString stringWithFormat:
            @"结束时间 %.2fs 超过视频时长 %.2fs", e, dur]];
        return;
    }

    VCAP_SetDict(@{sk: @(s), ek: @(e)});
    [self refreshStatus];
    VCAP_Log([NSString stringWithFormat:@"saved %@: [%.3f, %.3f]", sk, s, e]);
}

- (void)alertInvalid:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"无效输入"
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = [self findRootVC];
    if (root) [root presentViewController:a animated:YES completion:nil];
}

- (void)resetAll {
    VCAP_SetDict(@{
        kBlinkStartKey: @1.0, kBlinkEndKey: @2.0,
        kMouthStartKey: @2.5, kMouthEndKey: @3.5,
        kHeadStartKey:  @4.0, kHeadEndKey:  @5.5,
        kActiveKey: @0,
    });
    _activeAction = 0;
    [self refreshStatus];
    [self highlightAction:0];
    VCAP_Log(@"reset all");
}

@end

// ============================================================
//  入口（由 Tweak.m 的 initializeInSpringBoard 显式调用）
// ============================================================
void vcap_init(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *proc = [[[NSProcessInfo processInfo] processName] lowercaseString];
            if (![proc containsString:@"springboard"]) return;
            [VCamActionPatch install];
        });
    }
}
