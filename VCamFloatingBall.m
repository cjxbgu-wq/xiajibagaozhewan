//
//  VCamFloatingBall.m
//  悬浮球 + 控制面板
//  功能: 选择视频 / 禁用视频 / 旋转 / 放大 / 缩小
//        + 动作面板(VCamActionPatch 注入 tab)
//        + 隐藏悬浮球(VCamHidePatch 注入按钮)
//

#import "VCamFloatingBall.h"
#import "VCamCore.h"
#import "VCamNotify.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#include <dlfcn.h>
#include <pthread.h>
#import <mach/mach.h>
#import <objc/runtime.h>

// ============================================================
//  日志
// ============================================================
static void vcam_ball_log(NSString *msg) {
    @try {
        NSString *logPath = @"/var/mobile/Media/DCIM/vcam_ball_log.txt";
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// ============================================================
//  触摸穿透 window
// ============================================================
@interface VCamOverlayWindow : UIWindow
@end
@implementation VCamOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

// ============================================================
//  悬浮球视图
// ============================================================
@interface VCamBallView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@end
@implementation VCamBallView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithRed:0.75 green:0.76 blue:0.78 alpha:1.0].CGColor;

        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:26
                                                            weight:UIImageSymbolWeightSemibold];
        UIImage *icon = [UIImage systemImageNamed:@"video.fill" withConfiguration:cfg];
        _iconView = [[UIImageView alloc] initWithImage:icon];
        _iconView.tintColor = [UIColor colorWithRed:0.85 green:0.86 blue:0.88 alpha:1.0];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.frame = CGRectMake(6, 6, frame.size.width - 12, frame.size.height - 12);
        _iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_iconView];
    }
    return self;
}
@end

@interface VCamPanelButton : UIButton
@property (nonatomic, copy) NSString *buttonKey;
@end
@implementation VCamPanelButton
@end

// ============================================================
//  VCamFloatingBall
// ============================================================
@interface VCamFloatingBall () <PHPickerViewControllerDelegate>

@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) VCamBallView *ballView;
@property (nonatomic, strong) UIView *panelView;

// tab 行（VCamActionPatch 会 KVC 找 tabControlBtn / controlPageView 注入"动作"页）
@property (nonatomic, strong) UIButton *tabControlBtn;
@property (nonatomic, strong) UIView *controlPageView;

// 替换按钮引用（用于刷新标题/边框）
@property (nonatomic, strong) VCamPanelButton *replaceBtn;

@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL isFloating;

@end

@implementation VCamFloatingBall

+ (instancetype)sharedInstance {
    static VCamFloatingBall *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamFloatingBall alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _panelVisible = NO;
        _isFloating = NO;
    }
    return self;
}

#pragma mark - 显示/隐藏

- (void)showFloatingBall {
    if (_isFloating) return;
    _isFloating = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createOverlayWindow];
    });
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)hideFloatingBall {
    if (!_isFloating) return;
    _isFloating = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.overlayWindow removeFromSuperview];
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
        self.ballView = nil;
        self.panelView = nil;
    });
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI 创建

- (void)createOverlayWindow {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    UIWindowScene *windowScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            windowScene = (UIWindowScene *)scene;
            break;
        }
    }
    if (!windowScene) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    if (windowScene) {
        _overlayWindow = [[VCamOverlayWindow alloc] initWithWindowScene:windowScene];
    } else {
        _overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screenBounds];
    }
    _overlayWindow.frame = screenBounds;
    _overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    _overlayWindow.backgroundColor = [UIColor clearColor];
    _overlayWindow.rootViewController = [[UIViewController alloc] init];
    _overlayWindow.hidden = NO;
    _overlayWindow.userInteractionEnabled = YES;

    CGFloat ballSize = 50;
    CGFloat ballX = screenBounds.size.width - ballSize - 20;
    CGFloat ballY = screenBounds.size.height / 2 - ballSize / 2;
    _ballView = [[VCamBallView alloc] initWithFrame:CGRectMake(ballX, ballY, ballSize, ballSize)];
    UITapGestureRecognizer *tapGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTapped:)];
    [_ballView addGestureRecognizer:tapGesture];
    UIPanGestureRecognizer *panGesture =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballDragged:)];
    [_ballView addGestureRecognizer:panGesture];

    [self createPanel];
    [_overlayWindow addSubview:_ballView];
}

#pragma mark - 灰色主题

- (UIColor *)vcPanelBgColor {
    return [UIColor colorWithRed:0.24 green:0.25 blue:0.27 alpha:0.94];
}
- (UIColor *)vcButtonBgColor {
    return [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
}

- (VCamPanelButton *)makeButton:(NSString *)title frame:(CGRect)frame selector:(SEL)sel {
    VCamPanelButton *btn = [VCamPanelButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [self vcButtonBgColor];
    btn.layer.cornerRadius = 9;
    btn.layer.masksToBounds = YES;
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [btn addTarget:self action:@selector(buttonTouchDown:) forControlEvents:UIControlEventTouchDown];
    [btn addTarget:self action:@selector(buttonTouchUp:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return btn;
}

- (void)buttonTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.05 animations:^{
        sender.backgroundColor = [UIColor colorWithRed:0.62 green:0.63 blue:0.66 alpha:1.0];
    }];
}
- (void)buttonTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.12 animations:^{
        sender.backgroundColor = [self vcButtonBgColor];
    }];
}

#pragma mark - 面板创建

- (void)createPanel {
    CGFloat panelW = 241;
    CGFloat pad = 10;
    CGFloat contentW = panelW - pad * 2;    // 221
    CGFloat tabH = 30;
    CGFloat rowH = 38;                       // 整宽按钮高度
    CGFloat cellH = 52;                      // 双列按钮高度
    CGFloat gap = 8;

    // 控制页内容高度: 选择视频 + [禁用|旋转] + [−|+]
    CGFloat controlH = rowH + gap + cellH + gap + cellH;
    CGFloat pageTop = pad + tabH + 6;
    CGFloat panelH = pageTop + controlH + pad;

    _panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
    _panelView.backgroundColor = [self vcPanelBgColor];
    _panelView.layer.cornerRadius = 12;
    _panelView.layer.masksToBounds = YES;
    _panelView.alpha = 0;
    _panelView.hidden = YES;

    // ===== tab 行: 控制(动作 tab 由 VCamActionPatch 注入到右侧) =====
    CGFloat tabW = 64;
    _tabControlBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabControlBtn.frame = CGRectMake(pad, pad, tabW, tabH);
    [_tabControlBtn setTitle:@"控制" forState:UIControlStateNormal];
    _tabControlBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabControlBtn.layer.cornerRadius = 7;
    _tabControlBtn.backgroundColor = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    [_tabControlBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_panelView addSubview:_tabControlBtn];

    // ===== 控制页 =====
    _controlPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, controlH)];
    _controlPageView.backgroundColor = [UIColor clearColor];
    [_panelView addSubview:_controlPageView];

    // 行 1: 选择视频(整宽)
    VCamPanelButton *selectBtn = [self makeButton:@"选择视频"
                                            frame:CGRectMake(pad, 0, contentW, rowH)
                                          selector:@selector(selectVideoTapped)];
    selectBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_controlPageView addSubview:selectBtn];

    // 行 2: [禁用视频] [旋转]
    CGFloat colGap = 8;
    CGFloat colW = (contentW - colGap) / 2.0;
    CGFloat row2Y = rowH + gap;

    VCamPanelButton *replaceBtn = [self makeButton:@"禁用视频"
                                             frame:CGRectMake(pad, row2Y, colW, cellH)
                                           selector:@selector(toggleReplacementTapped)];
    replaceBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_controlPageView addSubview:replaceBtn];
    _replaceBtn = replaceBtn;

    VCamPanelButton *rotateBtn = [self makeButton:@"旋转"
                                            frame:CGRectMake(pad + colW + colGap, row2Y, colW, cellH)
                                          selector:@selector(rotateRightTapped)];
    rotateBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_controlPageView addSubview:rotateBtn];

    // 行 3: [−] [+]
    CGFloat row3Y = row2Y + cellH + gap;

    VCamPanelButton *zoomOutBtn = [self makeButton:@"−"
                                             frame:CGRectMake(pad, row3Y, colW, cellH)
                                           selector:@selector(zoomOutTapped)];
    zoomOutBtn.titleLabel.font = [UIFont boldSystemFontOfSize:26];
    [_controlPageView addSubview:zoomOutBtn];

    VCamPanelButton *zoomInBtn = [self makeButton:@"+"
                                            frame:CGRectMake(pad + colW + colGap, row3Y, colW, cellH)
                                          selector:@selector(zoomInTapped)];
    zoomInBtn.titleLabel.font = [UIFont boldSystemFontOfSize:26];
    [_controlPageView addSubview:zoomInBtn];

    [self updateReplaceButtonVisual];
    [_overlayWindow addSubview:_panelView];
}

- (void)updateReplaceButtonVisual {
    BOOL en = [VCamNotify isPlistEnabled];
    // 替换开启 → 按钮显示"禁用视频"(点一下关闭); 关闭 → "启用视频"
    [_replaceBtn setTitle:(en ? @"禁用视频" : @"启用视频") forState:UIControlStateNormal];
    _replaceBtn.layer.borderWidth = 2;
    _replaceBtn.layer.borderColor = en
        ? [UIColor colorWithRed:0.30 green:0.85 blue:0.45 alpha:1.0].CGColor
        : [UIColor clearColor].CGColor;
}

#pragma mark - 控制页回调

- (void)selectVideoTapped {
    if (!NSClassFromString(@"PHPickerViewController")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        [self.overlayWindow.rootViewController presentViewController:picker
                                                            animated:YES
                                                          completion:nil];
    });
}

// 禁用视频 / 启用视频 (替/原)
- (void)toggleReplacementTapped {
    BOOL newEnabled = ![VCamNotify isPlistEnabled];
    [VCamNotify setPlistEnabled:newEnabled];
    [[VCamCore sharedInstance] setEnabled:newEnabled];
    [self updateReplaceButtonVisual];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] replace -> %@", newEnabled ? @"ON" : @"OFF"]);
}

// 旋转 90°(顺时针, 以 plist 为单一事实源)
- (void)rotateRightTapped {
    int oldAngle = (int)[VCamNotify plistRotation];
    int newAngle = (oldAngle + 90) % 360;
    [VCamNotify setPlistRotation:newAngle];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] rotation: %d -> %d", oldAngle, newAngle]);
}

// ===== 缩放 zoomIn / zoomOut =====
// 每次 ×1.10 / ÷1.10, clamp [0.5, 4.0]
static double vcamTZoomFactor(void) { return 1.10; }
static double vcamTZoomMin(void)    { return 0.5; }
static double vcamTZoomMax(void)    { return 4.0; }

static double vcamClamp(double v, double lo, double hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

- (void)zoomInTapped {
    double nz = vcamClamp([VCamNotify plistZoom] * vcamTZoomFactor(),
                          vcamTZoomMin(), vcamTZoomMax());
    [VCamNotify setPlistZoom:nz];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] zoom in -> %.2f", nz]);
}

- (void)zoomOutTapped {
    double nz = vcamClamp([VCamNotify plistZoom] / vcamTZoomFactor(),
                          vcamTZoomMin(), vcamTZoomMax());
    [VCamNotify setPlistZoom:nz];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] zoom out -> %.2f", nz]);
}

// 换视频时清旋转 + 清缩放(避免旧状态污染新视频)
- (void)resetOrientationState {
    [VCamNotify setPlistRotation:0];
    [VCamNotify resetPlistTransform];   // 只清 pan/zoom, 保留 mirror 字段不动
}

#pragma mark - 交互

- (void)ballTapped:(UITapGestureRecognizer *)gesture {
    [self togglePanel];
}

- (void)ballDragged:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:_overlayWindow];
    CGPoint newCenter = CGPointMake(_ballView.center.x + translation.x,
                                    _ballView.center.y + translation.y);
    CGFloat halfW = _ballView.frame.size.width / 2;
    CGFloat halfH = _ballView.frame.size.height / 2;
    newCenter.x = MAX(halfW, MIN(_overlayWindow.frame.size.width - halfW, newCenter.x));
    newCenter.y = MAX(halfH, MIN(_overlayWindow.frame.size.height - halfH, newCenter.y));
    _ballView.center = newCenter;
    [gesture setTranslation:CGPointZero inView:_overlayWindow];
    [self updatePanelPosition];
}

- (void)togglePanel {
    _panelVisible = !_panelVisible;
    if (_panelVisible) {
        _panelView.hidden = NO;
        [self updatePanelPosition];
        [UIView animateWithDuration:0.2 animations:^{
            self.panelView.alpha = 1.0;
        }];
    } else {
        [UIView animateWithDuration:0.2 animations:^{
            self.panelView.alpha = 0;
        } completion:^(BOOL finished) {
            self.panelView.hidden = YES;
        }];
    }
}

- (void)updatePanelPosition {
    CGFloat panelW = _panelView.frame.size.width;
    CGFloat panelH = _panelView.frame.size.height;
    CGFloat screenW = _overlayWindow.frame.size.width;
    CGFloat screenH = _overlayWindow.frame.size.height;
    CGFloat gap = 8;
    CGFloat rightX = CGRectGetMaxX(_ballView.frame) + gap;
    CGFloat leftX = _ballView.frame.origin.x - panelW - gap;
    CGFloat panelX = (rightX + panelW <= screenW - 5) ? rightX : leftX;
    panelX = MAX(5, panelX);
    CGFloat panelY = _ballView.center.y - panelH / 2;
    panelY = MAX(5, MIN(screenH - panelH - 5, panelY));
    _panelView.frame = CGRectMake(panelX, panelY, panelW, panelH);
}

#pragma mark - 视频选择

- (BOOL)providerLooksLikeVideo:(NSItemProvider *)provider {
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) return YES;
    if ([provider hasItemConformingToTypeIdentifier:@"public.audiovisual-content"]) return YES;
    for (NSString *tid in provider.registeredTypeIdentifiers) {
        if ([tid containsString:@"movie"] || [tid containsString:@"video"] ||
            [tid containsString:@"mpeg-4"] || [tid containsString:@"quicktime"]) {
            return YES;
        }
    }
    return NO;
}

- (void)loadVideoFromProvider:(NSItemProvider *)provider
                   candidates:(NSArray<NSString *> *)cands {
    __weak typeof(self) weakSelf = self;
    NSString *tid = cands.firstObject;
    [provider loadFileRepresentationForTypeIdentifier:tid
                                    completionHandler:^(NSURL *url, NSError *error) {
        VCamFloatingBall *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!url) {
            if (cands.count > 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf loadVideoFromProvider:provider
                                           candidates:[cands subarrayWithRange:
                                                       NSMakeRange(1, cands.count - 1)]];
                });
            }
            return;
        }
        [strongSelf savePickedVideoAt:url];
    }];
}

- (void)savePickedVideoAt:(NSURL *)srcUrl {
    NSString *dest = @"/var/mobile/Media/DCIM/vcam.mp4";
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:dest error:nil];
    NSError *copyErr = nil;
    BOOL ok = [fm copyItemAtPath:srcUrl.path toPath:dest error:&copyErr];
    if (ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCamNotify setActivePlaybackPath:dest];
            [self resetOrientationState];
            if (![VCamNotify isPlistEnabled]) {
                [VCamNotify setPlistEnabled:YES];
                [[VCamCore sharedInstance] setEnabled:YES];
                [self updateReplaceButtonVisual];
            }
        });
        vcam_ball_log(@"[vcam] picker copy OK -> vcam.mp4");
    } else {
        vcam_ball_log([NSString stringWithFormat:@"[vcam] picker copy FAILED: %@", copyErr]);
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    NSItemProvider *provider = results.firstObject.itemProvider;

    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [cands addObject:@"public.movie"];
    }
    for (NSString *tid in provider.registeredTypeIdentifiers) {
        if ([cands containsObject:tid]) continue;
        if ([tid containsString:@"movie"] || [tid containsString:@"video"] ||
            [tid containsString:@"mpeg-4"] || [tid containsString:@"quicktime"]) {
            [cands addObject:tid];
        }
    }
    if (cands.count == 0) [cands addObject:@"public.movie"];
    [self loadVideoFromProvider:provider candidates:cands];
}

#pragma mark - 前后台

- (void)appDidBecomeActive:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_isFloating && self.overlayWindow && self.overlayWindow.windowScene == nil) {
            [self.overlayWindow removeFromSuperview];
            self.overlayWindow = nil;
            [self createOverlayWindow];
        }
    });
}

@end
