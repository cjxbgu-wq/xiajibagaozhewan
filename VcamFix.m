//
//  VcamFix.m — 补丁（源码零改动）
//
//  1. 强制 plist decodeMaxEdge=0 (不压缩视频, 保留原分辨率)
//  2. 门禁刷 + 播放器卡死自愈 (视频播放保障)
//  3. 绿边修复: swizzle GPUImageProcessor.transferPixelBuffer:toPixelBuffer:token:
//  4. 换视频清缓存: timer 检测 plist activePlaybackPath 变化 → 清 VCamCore 缓存
//  5. VCamHidePatch 三指呼出 + hideBtn 位置修复
//  6. 控制 tab 切回
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VCamNotify.h"

typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
extern OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
extern OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
extern OSStatus VTSessionSetProperty(CFTypeRef, CFStringRef, CFTypeRef);

static dispatch_source_t gTimerMD    = nil;
static dispatch_source_t gTimerSB    = nil;
static dispatch_source_t gTimerPath  = nil;

#pragma mark - 日志

static void VcamFix_Log(NSString *msg) {
    NSString *entry = [NSString stringWithFormat:@"[%@][fix] %@\n", [NSDate date], msg];
    NSArray *paths = @[@"/tmp/vcam_fix_log.txt", @"/var/mobile/Media/DCIM/vcam_fix_log.txt"];
    for (NSString *p in paths) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                if ([entry writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) break;
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
                break;
            }
        } @catch (...) {}
    }
}

#pragma mark - 类名兼容

static Class VcamFix_BallClass(void) {
    Class c = NSClassFromString(@"Jx6");
    return c ?: NSClassFromString(@"VCamFloatingBall");
}
static id VcamFix_BallInstance(void) {
    Class c = VcamFix_BallClass();
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    IMP f = [c methodForSelector:s];
    return f ? ((id(*)(id,SEL))f)(c, s) : nil;
}
static Class VcamFix_CoreClass(void) {
    Class c = NSClassFromString(@"Qz1");
    return c ?: NSClassFromString(@"VCamCore");
}
static id VcamFix_CoreInstance(void) {
    Class c = VcamFix_CoreClass();
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    IMP f = [c methodForSelector:s];
    return f ? ((id(*)(id,SEL))f)(c, s) : nil;
}

static NSString *VcamFix_PlistPath(void) { return @"/var/mobile/Media/DCIM/vc.plist"; }
static BOOL VcamFix_ReadEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}

#pragma mark - 修复 1: 强制关闭降采样

__attribute__((constructor, used))
static void VcamFixEarlyInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        if (![proc isEqualToString:@"mediaserverd"] && ![proc isEqualToString:@"lskdd"]) return;
        NSString *plist = VcamFix_PlistPath();
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:plist];
        if (!d) return;
        NSInteger cur = [d[@"decodeMaxEdge"] integerValue];
        if (cur != 0) {
            d[@"decodeMaxEdge"] = @(0);
            [d writeToFile:plist atomically:YES];
            VcamFix_Log([NSString stringWithFormat:@"decodeMaxEdge forced to 0 (was %ld)", (long)cur]);
        }
    }
}

#pragma mark - 修复 3: 绿边修复 (VcamFix 自带裁剪池 + Normal 缩放)

typedef struct {
    size_t w, h;
    CVPixelBufferRef buf;
    uint64_t token;
    CFAbsoluteTime lastUse;
} VcamFixCropSlot;
#define kVcamFixCropMax 4
static VcamFixCropSlot gVcamFixCrop[kVcamFixCropMax];
static NSLock *gVcamFixCropLock = nil;
static VTPixelTransferSessionRef gVcamFixNormalSess = NULL;

static void VcamFix_InitCrop(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gVcamFixCropLock = [[NSLock alloc] init];
    });
}

static VTPixelTransferSessionRef VcamFix_NormalSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VTPixelTransferSessionRef s = NULL;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
            VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Normal"));
            VTSessionSetProperty(s, CFSTR("RealTime"), kCFBooleanTrue);
            gVcamFixNormalSess = s;
            VcamFix_Log(@"[fix] normal VT session created");
        }
    });
    return gVcamFixNormalSess;
}

// 检查 Trim crop offset 是否非整数
static BOOL VcamFix_NeedCropFix(CVPixelBufferRef src, CVPixelBufferRef dst) {
    size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src);
    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    if (!sw || !sh || !dw || !dh) return NO;
    double sc = MAX((double)dw / sw, (double)dh / sh);
    double cw = sw * sc - dw;
    double ch = sh * sc - dh;
    if (cw > 0.5) { double o = cw / 2.0; if (fabs(o - floor(o + 0.5)) > 1e-3) return YES; }
    if (ch > 0.5) { double o = ch / 2.0; if (fabs(o - floor(o + 0.5)) > 1e-3) return YES; }
    return NO;
}

// 中心整数裁剪到目标比例 (要求 src 是 BGRA)
static CVPixelBufferRef VcamFix_GetCropBuf(CVPixelBufferRef srcBGRA, CVPixelBufferRef dst, uint64_t token) {
    if (!srcBGRA || !dst) return NULL;
    size_t sw = CVPixelBufferGetWidth(srcBGRA), sh = CVPixelBufferGetHeight(srcBGRA);
    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    if (!sw || !sh || !dw || !dh) return NULL;

    double r = (double)dw / dh;
    size_t cw, ch;
    if ((double)sw / sh > r) { ch = sh; cw = (size_t)(sh * r); }
    else                     { cw = sw; ch = (size_t)(sw / r); }
    cw &= ~(size_t)1; ch &= ~(size_t)1;
    if (cw < 4 || ch < 4 || cw > sw || ch > sh) return NULL;
    size_t cx = (((sw - cw) / 2) & ~(size_t)1);
    size_t cy = (((sh - ch) / 2) & ~(size_t)1);

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    VcamFixCropSlot *slot = NULL;
    int lruIdx = 0;
    for (int i = 0; i < kVcamFixCropMax; i++) {
        if (gVcamFixCrop[i].buf &&
            gVcamFixCrop[i].w == cw && gVcamFixCrop[i].h == ch) {
            slot = &gVcamFixCrop[i]; break;
        }
        if (gVcamFixCrop[i].lastUse < gVcamFixCrop[lruIdx].lastUse) lruIdx = i;
    }
    if (!slot) {
        int idx = -1;
        for (int i = 0; i < kVcamFixCropMax; i++) {
            if (!gVcamFixCrop[i].buf) { idx = i; break; }
        }
        if (idx < 0) {
            idx = lruIdx;
            CVPixelBufferRelease(gVcamFixCrop[idx].buf);
            gVcamFixCrop[idx].buf = NULL;
        }
        CVPixelBufferRef nb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, cw, ch,
                                kCVPixelFormatType_32BGRA, NULL, &nb) != noErr || !nb) return NULL;
        gVcamFixCrop[idx].w = cw; gVcamFixCrop[idx].h = ch;
        gVcamFixCrop[idx].buf = nb;
        gVcamFixCrop[idx].token = 0;
        gVcamFixCrop[idx].lastUse = now;
        slot = &gVcamFixCrop[idx];
    }
    slot->lastUse = now;
    if (slot->token == token && token != 0) return slot->buf;

    BOOL copied = NO;
    if (CVPixelBufferLockBaseAddress(srcBGRA, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        if (CVPixelBufferLockBaseAddress(slot->buf, 0) == kCVReturnSuccess) {
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddress(srcBGRA);
            uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(slot->buf);
            size_t srb = CVPixelBufferGetBytesPerRow(srcBGRA);
            size_t drb = CVPixelBufferGetBytesPerRow(slot->buf);
            if (sb && db && srb >= cw * 4 && drb >= cw * 4) {
                size_t rowBytes = cw * 4;
                for (size_t y = 0; y < ch; y++) {
                    memcpy(db + y * drb, sb + (cy + y) * srb + cx * 4, rowBytes);
                }
                slot->token = token;
                copied = YES;
            }
            CVPixelBufferUnlockBaseAddress(slot->buf, 0);
        }
        CVPixelBufferUnlockBaseAddress(srcBGRA, kCVPixelBufferLock_ReadOnly);
    }
    return copied ? slot->buf : NULL;
}

static BOOL (*gOrig_transfer)(id, SEL, CVPixelBufferRef, CVPixelBufferRef, uint64_t) = NULL;

static BOOL VcamFix_transfer(id self, SEL _cmd, CVPixelBufferRef src, CVPixelBufferRef dst, uint64_t token) {
    if (!src || !dst) return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;

    // 只在 Trim crop offset 非整数时触发 (CPU 计算无开销)
    if (!VcamFix_NeedCropFix(src, dst)) {
        return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;
    }

    VcamFix_InitCrop();
    [gVcamFixCropLock lock];

    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    CVPixelBufferRef srcBGRA = src;
    CVPixelBufferRef tmp = NULL;
    if (srcFmt != kCVPixelFormatType_32BGRA) {
        SEL sConv = NSSelectorFromString(@"convertFormat:toFormat:");
        if ([self respondsToSelector:sConv]) {
            tmp = ((CVPixelBufferRef(*)(id,SEL,CVPixelBufferRef,OSType))
                   [self methodForSelector:sConv])(self, sConv, src, kCVPixelFormatType_32BGRA);
            if (tmp) srcBGRA = tmp;
        }
    }

    BOOL ok = NO;
    if (srcBGRA) {
        CVPixelBufferRef cropped = VcamFix_GetCropBuf(srcBGRA, dst, token);
        if (cropped) {
            VTPixelTransferSessionRef ns = VcamFix_NormalSession();
            if (ns && VTPixelTransferSessionTransferImage(ns, cropped, dst) == noErr) {
                ok = YES;
                static CFAbsoluteTime lastLog = 0;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastLog > 5.0) {
                    lastLog = now;
                    VcamFix_Log([NSString stringWithFormat:
                        @"[fix] green-edge fixed %zux%zu -> %zux%zu",
                        CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src),
                        CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst)]);
                }
            }
        }
    }

    if (tmp) CVPixelBufferRelease(tmp);
    [gVcamFixCropLock unlock];

    if (ok) return YES;
    return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;
}

#pragma mark - 修复 4: 换视频清缓存

static NSString *gLastActivePath = nil;

static void VcamFix_ClearCoreBuffers(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;
    uint8_t *base = (uint8_t *)(__bridge void *)core;

    NSLock *pLock = nil;
    @try { pLock = [core valueForKey:@"processLock"]; } @catch (...) {}
    NSLock *rLock = nil;
    @try { rLock = [core valueForKey:@"renderLock"]; } @catch (...) {}

    if (pLock) [pLock lock];
    const char *ivars1[] = {"_liveYUVPixelBuffer", "_liveBGRAPixelBuffer", "_syncDisplayFrame", NULL};
    for (int i = 0; ivars1[i]; i++) {
        Ivar iv = class_getInstanceVariable(cls, ivars1[i]);
        if (!iv) continue;
        CVPixelBufferRef b = *(CVPixelBufferRef *)(base + ivar_getOffset(iv));
        if (b) {
            CVPixelBufferRelease(b);
            *(CVPixelBufferRef *)(base + ivar_getOffset(iv)) = NULL;
        }
    }
    if (pLock) [pLock unlock];

    if (rLock) [rLock lock];
    Ivar ivFb = class_getInstanceVariable(cls, "_fallbackFrame");
    if (ivFb) {
        CVPixelBufferRef b = *(CVPixelBufferRef *)(base + ivar_getOffset(ivFb));
        if (b) {
            CVPixelBufferRelease(b);
            *(CVPixelBufferRef *)(base + ivar_getOffset(ivFb)) = NULL;
        }
    }
    Ivar ivDedupBuf = class_getInstanceVariable(cls, "_dedupLastBuffer");
    if (ivDedupBuf) *(CVPixelBufferRef *)(base + ivar_getOffset(ivDedupBuf)) = NULL;
    Ivar ivDedupT = class_getInstanceVariable(cls, "_dedupLastTime");
    if (ivDedupT) *(CFAbsoluteTime *)(base + ivar_getOffset(ivDedupT)) = 0;
    Ivar ivDedupPts = class_getInstanceVariable(cls, "_dedupLastPts");
    if (ivDedupPts) *(double *)(base + ivar_getOffset(ivDedupPts)) = 0;
    Ivar ivAdvPts = class_getInstanceVariable(cls, "_lastAdvancePts");
    if (ivAdvPts) *(double *)(base + ivar_getOffset(ivAdvPts)) = 0;
    if (rLock) [rLock unlock];
}

static void VcamFix_PathCheck(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (!d) return;
        NSString *curPath = d[@"activePlaybackPath"];
        if (curPath.length == 0) return;

        if (gLastActivePath == nil) {
            gLastActivePath = [curPath copy];
            return;
        }
        if (![curPath isEqualToString:gLastActivePath]) {
            VcamFix_Log([NSString stringWithFormat:
                @"[fix] path change %@ -> %@, clearing core buffers",
                gLastActivePath.lastPathComponent, curPath.lastPathComponent]);
            VcamFix_ClearCoreBuffers();
            gLastActivePath = [curPath copy];
        }
    } @catch (...) {}
}

#pragma mark - 修复 2: 门禁 + 播放器卡死自愈

static void VcamFix_SyncEnabled(void) {
    Class cls = VcamFix_CoreClass();
    if (!cls) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;
    uint8_t *base = (uint8_t *)(__bridge void *)core;

    Ivar ivMd = class_getInstanceVariable(cls, "_isMediaserverdProcess");
    if (!ivMd) return;
    if (!*(BOOL *)(base + ivar_getOffset(ivMd))) return;

    Ivar ivG = class_getInstanceVariable(cls, "_licGate");
    Ivar ivM = class_getInstanceVariable(cls, "_licMark");
    if (ivG) *(BOOL *)(base + ivar_getOffset(ivG)) = YES;
    if (ivM) *(BOOL *)(base + ivar_getOffset(ivM)) = YES;

    SEL sSet = NSSelectorFromString(@"setEnabled:");
    if (![core respondsToSelector:sSet]) return;
    IMP impSet = [core methodForSelector:sSet];
    if (!impSet) return;

    BOOL plistEn = VcamFix_ReadEnabled();
    Ivar ivEn = class_getInstanceVariable(cls, "_enabled");
    if (!ivEn) return;
    BOOL cur = *(BOOL *)(base + ivar_getOffset(ivEn));

    if (cur != plistEn) {
        ((void(*)(id,SEL,BOOL))impSet)(core, sSet, plistEn);
        VcamFix_Log([NSString stringWithFormat:@"setEnabled:%d", (int)plistEn]);
        return;
    }
    if (!plistEn || !cur) return;

    CVPixelBufferRef live = NULL;
    Ivar ivLiveY = class_getInstanceVariable(cls, "_liveYUVPixelBuffer");
    if (ivLiveY) live = *(CVPixelBufferRef *)(base + ivar_getOffset(ivLiveY));

    id player = nil;
    @try { player = [core valueForKey:@"videoPlayer"]; } @catch (...) {}
    if (!player) return;
    uint64_t fc = 0;
    Ivar ivFc = class_getInstanceVariable([player class], "_frameCount");
    if (!ivFc) ivFc = class_getInstanceVariable([player class], "frameCount");
    if (ivFc) fc = *(uint64_t *)((uint8_t *)(__bridge void *)player + ivar_getOffset(ivFc));

    static uint64_t lastFc = 0;
    static int stuckTicks = 0;
    static CFAbsoluteTime lastForceAt = 0;

    if (fc == lastFc && !live) {
        stuckTicks++;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (stuckTicks >= 20 && now - lastForceAt > 5.0) {
            lastForceAt = now; stuckTicks = 0;
            VcamFix_Log([NSString stringWithFormat:@"PLAYER STUCK (fc=%llu), force disable→enable",
                         (unsigned long long)fc]);
            ((void(*)(id,SEL,BOOL))impSet)(core, sSet, NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                ((void(*)(id,SEL,BOOL))impSet)(core, sSet, YES);
            });
        }
    } else stuckTicks = 0;
    lastFc = fc;
}

#pragma mark - render 入口刷门禁

static void (*gOrig_render)(id, SEL, CVPixelBufferRef, double) = NULL;
static void VcamFix_render(id self, SEL _cmd, CVPixelBufferRef pb, double pts) {
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
    if (gOrig_render) gOrig_render(self, _cmd, pb, pts);
}

#pragma mark - 修复 5: VCamHidePatch 三指呼出 + hideBtn

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
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
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
    [hb addTarget:self action:NSSelectorFromString(@"vchp_hideTapped") forControlEvents:UIControlEventTouchUpInside];
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

#pragma mark - 修复 6: 控制 tab 切回

@interface VcamFixCtrlTarget : NSObject
+ (instancetype)shared;
- (void)controlTabTapped:(id)sender;
@end
@implementation VcamFixCtrlTarget
+ (instancetype)shared {
    static VcamFixCtrlTarget *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VcamFixCtrlTarget alloc] init]; });
    return inst;
}
- (void)controlTabTapped:(id)sender {
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIView *panelView = nil, *controlPage = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    @try { controlPage = [ball valueForKey:@"controlPageView"]; } @catch (...) {}
    if (!panelView || !controlPage) return;
    controlPage.hidden = NO;
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;
    UIButton *ctrlBtn = nil;
    @try { ctrlBtn = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    UIButton *actBtn = [panelView viewWithTag:0x56435041];
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (ctrlBtn) ctrlBtn.backgroundColor = active;
    if (actBtn)  actBtn.backgroundColor  = inactive;
    CGFloat targetH = controlPage.frame.origin.y + controlPage.frame.size.height + 10;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = panelView.frame;
        f.size.height = targetH;
        panelView.frame = f;
    }];
}
@end

static void VcamFix_EnsureControlTabTarget(void) {
    id ball = VcamFix_BallInstance();
    if (!ball) return;
    UIButton *ctrlBtn = nil;
    @try { ctrlBtn = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    if (!ctrlBtn) return;
    BOOL has = NO;
    for (id t in [ctrlBtn allTargets]) {
        if ([t isKindOfClass:[VcamFixCtrlTarget class]]) { has = YES; break; }
    }
    if (!has) {
        [ctrlBtn addTarget:[VcamFixCtrlTarget shared]
                    action:@selector(controlTabTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    }
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
            VcamFix_Log([NSString stringWithFormat:@"md init pid=%d", getpid()]);

            // swizzle render 门禁
            Class coreCls = VcamFix_CoreClass();
            if (coreCls) {
                Method mr = class_getInstanceMethod(coreCls,
                    NSSelectorFromString(@"renderReplacementToPixelBuffer:pts:"));
                if (mr) {
                    gOrig_render = (void (*)(id,SEL,CVPixelBufferRef,double))method_getImplementation(mr);
                    method_setImplementation(mr, (IMP)VcamFix_render);
                }
            }

            // swizzle transfer 绿边修复
            Class gpuCls = NSClassFromString(@"Rk3");
            if (!gpuCls) gpuCls = NSClassFromString(@"GPUImageProcessor");
            if (gpuCls) {
                Method mt = class_getInstanceMethod(gpuCls,
                    NSSelectorFromString(@"transferPixelBuffer:toPixelBuffer:token:"));
                if (mt) {
                    gOrig_transfer = (BOOL (*)(id,SEL,CVPixelBufferRef,CVPixelBufferRef,uint64_t))method_getImplementation(mt);
                    method_setImplementation(mt, (IMP)VcamFix_transfer);
                    VcamFix_Log(@"[fix] swizzled transferPixelBuffer (green-edge fix)");
                }
            }

            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

            // 门禁刷 + 播放器自愈 (0.1s)
            gTimerMD = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerMD,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                (uint64_t)(0.1 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerMD, ^{
                @autoreleasepool { VcamFix_SyncEnabled(); }
            });
            dispatch_resume(gTimerMD);

            // 换视频检测 (0.15s)
            VcamFix_PathCheck();
            gTimerPath = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerPath,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                (uint64_t)(0.15 * NSEC_PER_SEC), (uint64_t)(0.03 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerPath, ^{
                @autoreleasepool { VcamFix_PathCheck(); }
            });
            dispatch_resume(gTimerPath);

        } else if (isSB) {
            VcamFix_Log([NSString stringWithFormat:@"sb init pid=%d", getpid()]);

            Class hideCls = NSClassFromString(@"VCamHidePatch");
            if (hideCls) {
                Method m1 = class_getClassMethod(hideCls, NSSelectorFromString(@"hideBall"));
                if (m1) method_setImplementation(m1, (IMP)VcamFix_hideBall);
                Method m2 = class_getClassMethod(hideCls, NSSelectorFromString(@"showBall"));
                if (m2) method_setImplementation(m2, (IMP)VcamFix_showBall);
                Method m3 = class_getClassMethod(hideCls, NSSelectorFromString(@"pollForPanelAndInjectButton"));
                if (m3) method_setImplementation(m3, (IMP)VcamFix_pollHide);
            }

            dispatch_queue_t q = dispatch_get_main_queue();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           q, ^{ VcamFix_EnsureControlTabTarget(); });
            gTimerSB = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerSB,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerSB, ^{
                @autoreleasepool { VcamFix_EnsureControlTabTarget(); }
            });
            dispatch_resume(gTimerSB);
        }
    }
}
