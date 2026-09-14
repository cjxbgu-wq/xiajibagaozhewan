//
//  VCamFloatingBall.m
//  悬浮球 + 控制面板（选择视频/播/替/转/镜/箭头/缩放/复位）
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

        // SF Symbol 图标（替代加密的 ball_icon.h）
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
@property (nonatomic, strong) VCamPanelButton *replaceBtn;
@property (nonatomic, strong) VCamPanelButton *mirrorBtn;
@property (nonatomic, strong) VCamPanelButton *playPauseBtn;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL isFloating;
@property (nonatomic, assign) BOOL isPaused;
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
        _isPaused = NO;
    }
    return self;
}

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
    CGFloat contentW = panelW - pad * 2;
    CGFloat rowH = 38;
    CGFloat gap = 8;

    CGFloat cellW = 50;
    CGFloat cellH = 44;
    CGFloat gridGap = 7;
    CGFloat gridW = cellW * 3 + gridGap * 2;
    CGFloat gridX = (panelW - gridW) / 2;
    CGFloat gridY = rowH + gap;
    CGFloat gridH = cellH * 4 + gridGap * 3;
    CGFloat controlH = rowH + gap + gridH;
    CGFloat panelH = pad + controlH + pad;

    _panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
    _panelView.backgroundColor = [self vcPanelBgColor];
    _panelView.layer.cornerRadius = 12;
    _panelView.layer.masksToBounds = YES;
    _panelView.alpha = 0;
    _panelView.hidden = YES;

    // 选择视频按钮
    VCamPanelButton *selectBtn = [self makeButton:@"选择视频"
                                            frame:CGRectMake(pad, pad, contentW, rowH)
                                          selector:@selector(selectVideoTapped)];
    selectBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_panelView addSubview:selectBtn];

    // 3x4 宫格
    typedef NS_ENUM(int, GridCellType) {
        CellEmpty,
        CellSymbol,
    };
    struct GridCell {
        GridCellType type;
        NSString *symbol;
        SEL action;
    };
    struct GridCell cells[4][3] = {
        { {CellSymbol, @"arrow.uturn.backward", @selector(resetTransformTapped)},
          {CellSymbol, @"arrow.up", @selector(panUpTapped)},
          {CellSymbol, @"rectangle.on.rectangle", @selector(mirrorTapped)} },
        { {CellSymbol, @"arrow.left", @selector(panLeftTapped)},
          {CellSymbol, @"arrow.down", @selector(panDownTapped)},
          {CellSymbol, @"arrow.right", @selector(panRightTapped)} },
        { {CellSymbol, @"minus", @selector(zoomOutTapped)},
          {CellSymbol, @"play.fill", @selector(playPauseTapped)},
          {CellSymbol, @"plus", @selector(zoomInTapped)} },
        { {CellSymbol, @"rotate.right", @selector(rotateRightTapped)},
          {CellSymbol, @"arrow.2.squarepath", @selector(toggleReplacementTapped)},
          {CellEmpty, nil, NULL} },
    };

    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 3; c++) {
            struct GridCell cell = cells[r][c];
            if (cell.type == CellEmpty) continue;
            CGRect f = CGRectMake(gridX + c * (cellW + gridGap),
                                  pad + gridY + r * (cellH + gridGap),
                                  cellW, cellH);
            VCamPanelButton *btn = [self makeButton:@"" frame:f selector:cell.action];
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:14
                                                                weight:UIImageSymbolWeightSemibold];
            UIImage *sym = [UIImage systemImageNamed:cell.symbol withConfiguration:cfg];
            if (sym) {
                [btn setImage:sym forState:UIControlStateNormal];
                btn.tintColor = [UIColor whiteColor];
                btn.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
            }
            [_panelView addSubview:btn];
            if (r == 2 && c == 1) _playPauseBtn = btn;
            if (r == 0 && c == 2) _mirrorBtn = btn;
            if (r == 3 && c == 1) _replaceBtn = btn;
        }
    }

    [self updateReplaceButtonVisual];
    [self updateMirrorButtonVisual];

    _isPaused = [VCamNotify plistPaused];
    [self refreshPlayPauseIcon];

    [_overlayWindow addSubview:_panelView];
}

- (void)updateReplaceButtonVisual {
    BOOL en = [VCamNotify isPlistEnabled];
    self.replaceBtn.layer.borderWidth = 2;
    self.replaceBtn.layer.borderColor = en ? [UIColor clearColor].CGColor
                                           : [UIColor whiteColor].CGColor;
}

- (void)updateMirrorButtonVisual {
    BOOL mi = [VCamNotify plistMirrored];
    self.mirrorBtn.layer.borderWidth = 2;
    self.mirrorBtn.layer.borderColor = mi ? [UIColor whiteColor].CGColor
                                          : [UIColor clearColor].CGColor;
}

- (void)refreshPlayPauseIcon {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *sym = [UIImage systemImageNamed:(_isPaused ? @"pause.fill" : @"play.fill")
                           withConfiguration:cfg];
    if (sym) {
        [_playPauseBtn setImage:sym forState:UIControlStateNormal];
        _playPauseBtn.tintColor = [UIColor whiteColor];
    }
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

- (void)toggleReplacementTapped {
    BOOL newEnabled = ![VCamNotify isPlistEnabled];
    [VCamNotify setPlistEnabled:newEnabled];
    [[VCamCore sharedInstance] setEnabled:newEnabled];
    [self updateReplaceButtonVisual];
}

- (void)playPauseTapped {
    _isPaused = !_isPaused;
    [VCamNotify setPlistPaused:_isPaused];
    [self refreshPlayPauseIcon];
}

#pragma mark - 用户画面变换

static double vcamTZoomFactor(void) { return 1.10; }
static double vcamTZoomMin(void)    { return 0.5; }
static double vcamTZoomMax(void)    { return 4.0; }
static double vcamTPanStep(void)    { return 0.05; }

static double vcamClamp(double v, double lo, double hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

- (void)panByX:(double)dx Y:(double)dy {
    double nx = vcamClamp([VCamNotify plistPanX] + dx, -1.0, 1.0);
    double ny = vcamClamp([VCamNotify plistPanY] + dy, -1.0, 1.0);
    [VCamNotify setPlistPanX:nx];
    [VCamNotify setPlistPanY:ny];
}

- (void)panLeftTapped  { [self panByX:-vcamTPanStep() Y:0]; }
- (void)panRightTapped { [self panByX: vcamTPanStep() Y:0]; }
- (void)panUpTapped    { [self panByX:0 Y:-vcamTPanStep()]; }
- (void)panDownTapped  { [self panByX:0 Y: vcamTPanStep()]; }

- (void)zoomInTapped {
    double nz = vcamClamp([VCamNotify plistZoom] * vcamTZoomFactor(),
                          vcamTZoomMin(), vcamTZoomMax());
    [VCamNotify setPlistZoom:nz];
}

- (void)zoomOutTapped {
    double nz = vcamClamp([VCamNotify plistZoom] / vcamTZoomFactor(),
                          vcamTZoomMin(), vcamTZoomMax());
    [VCamNotify setPlistZoom:nz];
}

- (void)resetTransformTapped {
    [VCamNotify resetPlistTransform];
}

- (void)rotateRightTapped {
    int oldAngle = (int)[VCamNotify plistRotation];
    int newAngle = (oldAngle + 90) % 360;
    [VCamNotify setPlistRotation:newAngle];
}

- (void)mirrorTapped {
    BOOL newMirrored = ![VCamNotify plistMirrored];
    [VCamNotify setPlistMirrored:newMirrored];
    [self updateMirrorButtonVisual];
}

- (void)resetOrientationState {
    [VCamNotify setPlistRotation:0];
    [VCamNotify setPlistMirrored:NO];
    [VCamNotify resetPlistTransform];
    [self updateMirrorButtonVisual];
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
