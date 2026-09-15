#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_all.py — 唯一补丁脚本（源码零改动，幂等）

合并修复：
  [编译]   VCamCore.m 962 行语法
  [问题1]  换视频残留（VcamFix mtime）
  [问题2]  拍照色彩（sRGB）
  [发热]   VcamFix 反射缓存 + timer 合并
  [卡顿]   轮询间隔 / 空闲 sleep 拉长
  [发热2]  禁用 VcamFix CPU 绿色边缘 crop
  [卡死]   禁用 PLAYER STUCK 强制自愈
  [卡密]   一机一码 + 设备码每次读文件 + 三 tab UI + 锁死逻辑
"""
import sys


def patch_file(path, old, new, tag):
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        print(f"!! 文件不存在: {path}", file=sys.stderr)
        return False
    if new.strip() in content and old.strip() not in content:
        print(f">> 已应用过，跳过: {path} [{tag}]")
        return True
    if old not in content:
        print(f"!! 未匹配: {path} [{tag}]", file=sys.stderr)
        return False
    content = content.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f">> 已修改: {path} [{tag}]")
    return True


# ============================================================
# [1] VCamCore.m — 962 行语法
# ============================================================
c962_old = '''NSString *replayPath = [strongSelf.videoPlayer currentVideoPath copy];'''
c962_new = '''NSString *replayPath = [[strongSelf.videoPlayer currentVideoPath] copy];'''


# ============================================================
# [2] VcamFix.m — 换视频残留（文件 mtime）
# ============================================================
vf_old = '''        if (gLastActivePath == nil) {
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
}'''
vf_new = '''        if (gLastActivePath == nil) {
            gLastActivePath = [curPath copy];
        } else if (![curPath isEqualToString:gLastActivePath]) {
            VcamFix_Log([NSString stringWithFormat:
                @"[fix] path change %@ -> %@, clearing core buffers",
                gLastActivePath.lastPathComponent, curPath.lastPathComponent]);
            VcamFix_ClearCoreBuffers();
            gLastActivePath = [curPath copy];
            return;
        }
        static double sLastMtime = 0;
        static unsigned long long sLastSize = 0;
        static NSString *sWatchedPath = nil;
        if (![sWatchedPath isEqualToString:curPath]) {
            sWatchedPath = [curPath copy];
            sLastMtime = 0; sLastSize = 0;
        }
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:curPath error:nil];
        if (attrs) {
            double mtime = [attrs.fileModificationDate timeIntervalSince1970];
            unsigned long long size = [attrs fileSize];
            if (sLastMtime > 0.0 &&
                (fabs(mtime - sLastMtime) > 0.5 || size != sLastSize)) {
                VcamFix_Log([NSString stringWithFormat:
                    @"[fix] media file changed (mtime %.3f->%.3f size %llu->%llu), clearing core buffers",
                    sLastMtime, mtime, sLastSize, size]);
                VcamFix_ClearCoreBuffers();
                id core = VcamFix_CoreInstance();
                if (core) {
                    id player = nil;
                    @try { player = [core valueForKey:@"videoPlayer"]; } @catch (...) {}
                    if (player) {
                        SEL selReload = NSSelectorFromString(@"reloadMedia");
                        if ([player respondsToSelector:selReload]) {
                            ((void(*)(id,SEL))[player methodForSelector:selReload])(player, selReload);
                            VcamFix_Log(@"[fix] triggered LocalVideoPlayer.reloadMedia");
                        }
                    }
                }
            }
            sLastMtime = mtime;
            sLastSize = size;
        }
    } @catch (...) {}
}'''


# ============================================================
# [3] VcamFix.m — CoreClass 缓存
# ============================================================
vc_old = '''static Class VcamFix_CoreClass(void) {
    Class c = NSClassFromString(@"Qz1");
    return c ?: NSClassFromString(@"VCamCore");
}'''
vc_new = '''static Class VcamFix_CoreClass(void) {
    static Class c = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = NSClassFromString(@"Qz1") ?: NSClassFromString(@"VCamCore");
    });
    return c;
}'''


# ============================================================
# [4] VcamFix.m — BallClass 缓存
# ============================================================
vb_old = '''static Class VcamFix_BallClass(void) {
    Class c = NSClassFromString(@"Jx6");
    return c ?: NSClassFromString(@"VCamFloatingBall");
}'''
vb_new = '''static Class VcamFix_BallClass(void) {
    static Class c = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = NSClassFromString(@"Jx6") ?: NSClassFromString(@"VCamFloatingBall");
    });
    return c;
}'''


# ============================================================
# [5] VcamFix.m — ReadEnabled mtime 缓存
# ============================================================
vr_old = '''static BOOL VcamFix_ReadEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}'''
vr_new = '''static BOOL VcamFix_ReadEnabled(void) {
    static BOOL sCached = NO;
    static double sLastMtime = -1.0;
    @try {
        NSString *path = VcamFix_PlistPath();
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path error:nil];
        double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0.0;
        if (mtime != sLastMtime) {
            sLastMtime = mtime;
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            if (d) sCached = [d[@"enabled"] boolValue];
        }
    } @catch (...) {}
    return sCached;
}'''


# ============================================================
# [6] VcamFix.m — SyncEnabled Ivar 缓存 + 删除 PLAYER STUCK
# ============================================================
vs_old = '''static void VcamFix_SyncEnabled(void) {
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
}'''
vs_new = '''static void VcamFix_SyncEnabled(void) {
    static Class sCls = NULL;
    static Ivar sIvMd = NULL, sIvG = NULL, sIvM = NULL, sIvEn = NULL;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        sCls = VcamFix_CoreClass();
        if (!sCls) return;
        sIvMd = class_getInstanceVariable(sCls, "_isMediaserverdProcess");
        sIvG = class_getInstanceVariable(sCls, "_licGate");
        sIvM = class_getInstanceVariable(sCls, "_licMark");
        sIvEn = class_getInstanceVariable(sCls, "_enabled");
    });
    if (!sCls || !sIvMd) return;
    id core = VcamFix_CoreInstance();
    if (!core) return;
    uint8_t *base = (uint8_t *)(__bridge void *)core;
    if (!*(BOOL *)(base + ivar_getOffset(sIvMd))) return;
    if (sIvG) *(BOOL *)(base + ivar_getOffset(sIvG)) = YES;
    if (sIvM) *(BOOL *)(base + ivar_getOffset(sIvM)) = YES;
    SEL sSet = NSSelectorFromString(@"setEnabled:");
    if (![core respondsToSelector:sSet]) return;
    IMP impSet = [core methodForSelector:sSet];
    if (!impSet) return;
    BOOL plistEn = VcamFix_ReadEnabled();
    if (!sIvEn) return;
    BOOL cur = *(BOOL *)(base + ivar_getOffset(sIvEn));
    if (cur != plistEn) {
        ((void(*)(id,SEL,BOOL))impSet)(core, sSet, plistEn);
        VcamFix_Log([NSString stringWithFormat:@"setEnabled:%d", (int)plistEn]);
        return;
    }
    // ★ 已删除 PLAYER STUCK 强制自愈（误判打断正常播放）
}'''


# ============================================================
# [7] VcamFix.m — 合并 timer
# ============================================================
vt_old = '''            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

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
            dispatch_resume(gTimerPath);'''
vt_new = '''            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            VcamFix_PathCheck();
            __block int sTick = 0;
            gTimerMD = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(gTimerMD,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                (uint64_t)(0.1 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimerMD, ^{
                @autoreleasepool {
                    VcamFix_SyncEnabled();
                    if (++sTick % 5 == 0) VcamFix_PathCheck();
                }
            });
            dispatch_resume(gTimerMD);'''


# ============================================================
# [8] VcamFix.m — 隐藏按钮尺寸限制
# ============================================================
hb_old = '''    CGFloat maxBottom = -1, cellH = 0;
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
    hb.frame = CGRectMake(pad, maxBottom + 8, cw, cellH);'''
hb_new = '''    CGFloat maxBottom = -1, cellH = 0;
    for (UIView *sub in cpv.subviews) {
        if (![sub isKindOfClass:[UIButton class]]) continue;
        CGRect f = sub.frame;
        CGFloat b = f.origin.y + f.size.height;
        if (b > maxBottom) { maxBottom = b; cellH = f.size.height; }
    }
    if (maxBottom < 0) return;
    if (cellH > 36) cellH = 36;

    CGFloat pad = 10;
    CGFloat cw = cpv.frame.size.width - pad * 2;
    UIButton *hb = [UIButton buttonWithType:UIButtonTypeSystem];
    hb.tag = 0x56434D31;
    hb.frame = CGRectMake(pad, maxBottom + 8, cw, cellH);'''


# ============================================================
# [9] VcamFix.m — 禁用 CPU 绿色边缘 crop
# ============================================================
f1_old = '''static BOOL VcamFix_transfer(id self, SEL _cmd, CVPixelBufferRef src, CVPixelBufferRef dst, uint64_t token) {
    if (!src || !dst) return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;

    // 只在 Trim crop offset 非整数时触发 (CPU 计算无开销)
    if (!VcamFix_NeedCropFix(src, dst)) {
        return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;
    }'''
f1_new = '''static BOOL VcamFix_transfer(id self, SEL _cmd, CVPixelBufferRef src, CVPixelBufferRef dst, uint64_t token) {
    // ★ 深度修复：完全移除 CPU green-edge crop
    //   原因：720x404 -> 1920x1080 逐行 memcpy 是发热/卡死的唯一根因
    //        原 crop 从未真正解决色彩问题，只徒增功耗
    return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;
}

static BOOL VcamFix_transfer_legacy(id self, SEL _cmd, CVPixelBufferRef src, CVPixelBufferRef dst, uint64_t token) {
    if (!src || !dst) return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;

    if (!VcamFix_NeedCropFix(src, dst)) {
        return gOrig_transfer ? gOrig_transfer(self, _cmd, src, dst, token) : NO;
    }'''


# ============================================================
# [10] VCamCore.m — 轮询 0.15s → 0.5s
# ============================================================
cp_old = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.15 callback:^(BOOL enabled) {'''
cp_new = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.5 callback:^(BOOL enabled) {'''


# ============================================================
# [11] VCamCore.m — 反注入扫描 30s → 120s
# ============================================================
cs_old = '''    if (snapshot && now - lastScan < 30.0) return lastRes;'''
cs_new = '''    if (snapshot && now - lastScan < 120.0) return lastRes;'''


# ============================================================
# [12] VCamCore.m — prerender 空闲 sleep 0.1s → 0.5s
# ============================================================
cpr_old = '''                if (strongSelf.pipelineIdle) {
                    [NSThread sleepForTimeInterval:0.1];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }'''
cpr_new = '''                if (strongSelf.pipelineIdle) {
                    [NSThread sleepForTimeInterval:0.5];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }'''


# ============================================================
# [13] LocalVideoPlayer.m — decodeLoop 空闲 sleep 0.1s → 0.5s
# ============================================================
ld_old = '''                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // 加载代数变化 → 解码线程自行重建 reader'''
ld_new = '''                    [NSThread sleepForTimeInterval:0.5];
                    continue;
                }

                // 加载代数变化 → 解码线程自行重建 reader'''


# ============================================================
# [14] Tweak.m — 拍照 sRGB
# ============================================================
ph_helper_old = '''static void (*orig_BWPhotoEncoderNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);'''
ph_helper_new = '''static void (*orig_BWPhotoEncoderNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);

static void vcamPhotoForceSRGB(CMSampleBufferRef sb, CVPixelBufferRef srcVideo) {
    if (!sb) return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    CFTypeRef srcMatrix = srcVideo ? CVBufferGetAttachment(srcVideo, kCVImageBufferYCbCrMatrixKey, NULL) : NULL;
    CFTypeRef srcPrim   = srcVideo ? CVBufferGetAttachment(srcVideo, kCVImageBufferColorPrimariesKey, NULL) : NULL;
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          srcMatrix ?: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          srcPrim ?: kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          CFSTR("IEC_sRGB"),
                          kCVAttachmentMode_ShouldPropagate);
}'''

ph_hook_old = '''static void hook_BWPhotoEncoderNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
        @autoreleasepool {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                @try {
                    [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer
                                                                         pts:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))];
                } @catch (NSException *e) {
                    vcam_tweak_log([NSString stringWithFormat:@"[vcam] PhotoEncoder hook exception: %@", e]);
                }
            }
        }
    }
    if (orig_BWPhotoEncoderNode_renderSampleBuffer) {
        orig_BWPhotoEncoderNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
    }
}'''
ph_hook_new = '''static void hook_BWPhotoEncoderNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
        @autoreleasepool {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                @try {
                    CVPixelBufferRef srcVideo = (__bridge CVPixelBufferRef)[[VCamCore sharedInstance] valueForKey:@"liveYUVPixelBuffer"];
                    [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer
                                                                         pts:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))];
                    vcamPhotoForceSRGB(sampleBuffer, srcVideo);
                } @catch (NSException *e) {
                    vcam_tweak_log([NSString stringWithFormat:@"[vcam] PhotoEncoder hook exception: %@", e]);
                }
            }
        }
    }
    if (orig_BWPhotoEncoderNode_renderSampleBuffer) {
        orig_BWPhotoEncoderNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
    }
}'''


# ============================================================
# [15] VCamActionPatch.m — 卡密系统（含设备码每次读文件）
# ============================================================
k1_old = '''// ============================================================
//  VCamActionPatch
// ============================================================
@interface VCamActionPatch : NSObject'''

k1_new = '''// ============================================================
//  卡密系统
// ============================================================
#import <CommonCrypto/CommonCrypto.h>
#include <sys/stat.h>

static NSString *vclp_salt(void) { return @"vcam_2026_salt_x9k7b3m"; }
static NSString *vclp_DevPath(void)  { return @"/var/mobile/Media/DCIM/vcam_devid.txt"; }
static NSString *vclp_DevBak(void)   { return @"/var/mobile/Media/DCIM/.vcam_devid"; }
static NSString *vclp_LicPath(void)  { return @"/var/mobile/Media/DCIM/vcam_license.plist"; }

// ★ 设备码：每次读文件，仅文件不存在时才计算并写一次
static NSString *vclp_DeviceCode(void) {
    NSString *raw = [NSString stringWithContentsOfFile:vclp_DevPath() encoding:NSUTF8StringEncoding error:nil];
    if (!raw || raw.length < 16) {
        raw = [NSString stringWithContentsOfFile:vclp_DevBak() encoding:NSUTF8StringEncoding error:nil];
    }
    raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 16) {
        return [NSString stringWithFormat:@"%@-%@-%@-%@",
             [raw substringWithRange:NSMakeRange(0,4)],
             [raw substringWithRange:NSMakeRange(4,4)],
             [raw substringWithRange:NSMakeRange(8,4)],
             [raw substringWithRange:NSMakeRange(12,4)]];
    }

    static NSString *computed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"";
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.vcam.ios";
        NSString *s0 = [NSString stringWithFormat:@"%@|%@|%@", idfv, bundle, vclp_salt()];
        const char *cstr = [s0 UTF8String];
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(cstr, (CC_LONG)strlen(cstr), hash);
        NSMutableString *hex = [NSMutableString stringWithCapacity:16];
        for (int i = 0; i < 8; i++) [hex appendFormat:@"%02X", hash[i]];
        NSString *h = hex;
        computed = [NSString stringWithFormat:@"%@-%@-%@-%@",
             [h substringWithRange:NSMakeRange(0,4)],
             [h substringWithRange:NSMakeRange(4,4)],
             [h substringWithRange:NSMakeRange(8,4)],
             [h substringWithRange:NSMakeRange(12,4)]];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:vclp_DevPath()]) {
            [h writeToFile:vclp_DevPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        if (![fm fileExistsAtPath:vclp_DevBak()]) {
            [h writeToFile:vclp_DevBak()  atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    });
    return computed;
}

static NSData *vclp_secret(void) {
    static NSData *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const unsigned char enc[32] = {
            0xFB,0xE8,0x99,0x8E,0xBF,0xAC,0x5D,0x42,
            0x73,0x60,0x11,0x06,0x37,0x24,0xD5,0xCA,
            0x4B,0x78,0x69,0x1E,0x0F,0x3C,0x2D,0xD2,
            0xC3,0xF0,0xE1,0x96,0x87,0xB4,0xA5,0x5A,
        };
        unsigned char k[32];
        for (int i = 0; i < 32; i++) k[i] = enc[i] ^ 0x5A;
        s = [NSData dataWithBytes:k length:32];
    });
    return s;
}

static BOOL gVclpActivated = NO;
static NSInteger gVclpExpireAt = 0;

static NSInteger vclp_DaysFromCard(NSString *card16) {
    if (card16.length != 16) return -1;
    NSString *days4 = [card16 substringFromIndex:12];
    unsigned int v = 0;
    NSScanner *sc = [NSScanner scannerWithString:days4];
    if (![sc scanHexInt:&v]) return -1;
    if (!sc.isAtEnd) return -1;
    return (NSInteger)v;
}

static NSString *vclp_ExpectedSig(NSString *device, NSInteger days) {
    NSData *key = vclp_secret();
    NSString *input = [NSString stringWithFormat:@"%@|%ld", device, (long)days];
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, hmac);
    NSMutableString *out = [NSMutableString stringWithCapacity:12];
    for (int i = 0; i < 6; i++) [out appendFormat:@"%02X", hmac[i]];
    return out;
}

static void vclp_ApplyExpire(NSInteger days, NSInteger activatedAt) {
    if (days > 0) {
        gVclpExpireAt = activatedAt + days * 86400;
    } else {
        gVclpExpireAt = 0;
    }
}

static BOOL vclp_Validate(NSDictionary *d) {
    if (!d) return NO;
    NSString *device = d[@"deviceCode"];
    NSString *card = d[@"licenseCode"];
    NSNumber *activatedNum = d[@"activatedAt"];
    NSNumber *maxSeen = d[@"maxSeenAt"];
    if (!device || !card || !activatedNum) return NO;
    if (![device isEqualToString:vclp_DeviceCode()]) return NO;
    NSString *clean = [[card stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    if (clean.length != 16) return NO;
    NSString *sig12 = [clean substringToIndex:12];
    NSInteger days = vclp_DaysFromCard(clean);
    if (days < 0 || days > 1048575) return NO;
    if (![vclp_ExpectedSig(device, days) isEqualToString:sig12]) return NO;
    NSInteger activatedAt = [activatedNum integerValue];
    if (activatedAt <= 0) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (maxSeen && now < [maxSeen doubleValue] - 300) return NO;
    vclp_ApplyExpire(days, activatedAt);
    if (days > 0) {
        NSInteger nowSec = (NSInteger)now;
        if (nowSec > gVclpExpireAt) return NO;
    }
    return YES;
}

static void vclp_Load(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:vclp_LicPath()];
        if (!d) return;
        if (!vclp_Validate(d)) return;
        gVclpActivated = YES;
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:d];
        NSInteger newMax = MAX((NSInteger)CFAbsoluteTimeGetCurrent(), [m[@"maxSeenAt"] integerValue]);
        m[@"maxSeenAt"] = @(newMax);
        [m writeToFile:vclp_LicPath() atomically:YES];
    } @catch (...) {}
}

static BOOL vclp_Save(NSString *card) {
    @try {
        NSString *clean = [[card stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
        NSInteger days = vclp_DaysFromCard(clean);
        if (days < 0) return NO;
        NSInteger now = (NSInteger)[[NSDate date] timeIntervalSince1970];
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"deviceCode"]  = vclp_DeviceCode();
        m[@"licenseCode"] = clean;
        m[@"days"]        = @(days);
        m[@"activatedAt"] = @(now);
        m[@"maxSeenAt"]   = @(now);
        m[@"expireAt"]    = @(days > 0 ? now + days * 86400 : 0);
        vclp_ApplyExpire(days, now);
        BOOL ok = [m writeToFile:vclp_LicPath() atomically:YES];
        chmod([vclp_LicPath() UTF8String], 0644);
        return ok;
    } @catch (...) { return NO; }
}

static BOOL vclp_Verify(NSString *userInput) {
    NSString *card = [[userInput stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    card = [card stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (card.length != 16) return NO;
    NSString *sig12 = [card substringToIndex:12];
    NSInteger days = vclp_DaysFromCard(card);
    if (days < 0 || days > 1048575) return NO;
    return [vclp_ExpectedSig(vclp_DeviceCode(), days) isEqualToString:sig12];
}

static BOOL vclp_IsActivated(void) { return gVclpActivated; }
static void vclp_SetActivated(BOOL a) { gVclpActivated = a; }

BOOL vclp_IsActivated_External(void) {
    return vclp_IsActivated();
}

static void vclp_Init(void) {
    vclp_Load();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (double d = 1.0; d <= 5.0; d += 2.0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!vclp_IsActivated()) vclp_Load();
            });
        }
        [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *t) {
            vclp_Load();
        }];
    });
}

// ============================================================
//  VCamActionPatch
// ============================================================
@interface VCamActionPatch : NSObject'''

k2_old = '''+ (void)install {
    VCamActionPatch *s = [VCamActionPatch shared];
    if (s->_installed) return;
    s->_installed = YES;
    VCAP_Log(@"action install start");'''
k2_new = '''+ (void)install {
    VCamActionPatch *s = [VCamActionPatch shared];
    if (s->_installed) return;
    s->_installed = YES;
    vclp_Init();
    VCAP_Log(@"action install start");'''

k3_old = '''- (void)resetAll;
- (void)pollTick;
- (void)ensureInjected;
@end'''
k3_new = '''- (void)resetAll;
- (void)pollTick;
- (void)ensureInjected;
- (void)licenseTabTapped;
- (void)copyDeviceCode:(UIButton *)sender;
- (void)activateTapped:(UIButton *)sender;
- (void)refreshLicenseUI;
- (void)showLicenseAlert:(NSString *)title msg:(NSString *)msg;
- (UIView *)buildLicensePage:(CGFloat)panelW tabControl:(UIButton *)tabControl;
@end'''

k4_old = '''@implementation VCamActionPatch
{
    NSArray<UIButton *> *_actionBtns;
    NSArray<UIButton *> *_timeBtns;
    UILabel *_statusLabel;
    UILabel *_durationLabel;
    int _activeAction;
    BOOL _installed;
}'''
k4_new = '''@implementation VCamActionPatch
{
    NSArray<UIButton *> *_actionBtns;
    NSArray<UIButton *> *_timeBtns;
    UILabel *_statusLabel;
    UILabel *_durationLabel;
    int _activeAction;
    BOOL _installed;

    UIView *_licensePage;
    UITextField *_cardField;
    UIView *_licenseStatusRow;
    UILabel *_licenseStatusLabel;
    UILabel *_licenseDetailLabel;
    UIButton *_licenseTabBtn;
}'''

k5_old = '''- (void)injectIntoBall:(id)ball panelView:(UIView *)panelView {
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
    actionTab.frame = CGRectMake(x0 + tabW + tabGap, tabY, tabW, tabH);'''
k5_new = '''- (void)injectIntoBall:(id)ball panelView:(UIView *)panelView {
    UIButton *controlTab = nil;
    UIButton *lightTab = nil;
    @try { controlTab = [ball valueForKey:@"tabControlBtn"]; } @catch (...) {}
    if (!controlTab) return;

    CGFloat panelW = panelView.frame.size.width;
    CGFloat tabH = controlTab.frame.size.height;
    CGFloat tabY = controlTab.frame.origin.y;
    CGFloat tabGap = 6;
    CGFloat x0 = 10;
    CGFloat tabW = (panelW - x0 * 2 - tabGap * 2) / 3.0;

    controlTab.frame = CGRectMake(x0, tabY, tabW, tabH);

    // 动作 tab 按钮
    UIButton *actionTab = [UIButton buttonWithType:UIButtonTypeSystem];
    actionTab.tag = 0x56435041;
    actionTab.frame = CGRectMake(x0 + tabW + tabGap, tabY, tabW, tabH);'''

k5_old2 = '''    // 动作页
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
}'''
k5_new2 = '''    // 动作页
    UIView *page = [self buildActionPage:panelW tabControl:controlTab];
    page.tag = 0x56435042;
    page.hidden = YES;
    [panelView addSubview:page];

    // 验证 tab 按钮
    _licenseTabBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _licenseTabBtn.tag = 0x56435043;
    _licenseTabBtn.frame = CGRectMake(x0 + (tabW + tabGap) * 2, tabY, tabW, tabH);
    [_licenseTabBtn setTitle:@"验证" forState:UIControlStateNormal];
    _licenseTabBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _licenseTabBtn.layer.cornerRadius = 7;
    _licenseTabBtn.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    [_licenseTabBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_licenseTabBtn addTarget:self action:@selector(licenseTabTapped)
             forControlEvents:UIControlEventTouchUpInside];
    [panelView addSubview:_licenseTabBtn];

    // 验证页
    _licensePage = [self buildLicensePage:panelW tabControl:controlTab];
    _licensePage.tag = 0x56435044;
    _licensePage.hidden = YES;
    [panelView addSubview:_licensePage];

    // 切页联动
    if (controlTab) {
        [controlTab addTarget:self action:@selector(hideActionPageOnOtherTab)
             forControlEvents:UIControlEventTouchUpInside];
    }
    if (lightTab) {
        [lightTab addTarget:self action:@selector(hideActionPageOnOtherTab)
           forControlEvents:UIControlEventTouchUpInside];
    }

    VCAP_Log(@"action + license page injected");
}'''

k6_old = '''- (void)hideActionPageOnOtherTab {
    id ball = VCAP_FindBallInstance();
    if (!ball) return;
    UIView *panelView = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    if (!panelView) return;
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;
}'''
k6_new = '''- (void)hideActionPageOnOtherTab {
    id ball = VCAP_FindBallInstance();
    if (!ball) return;
    UIView *panelView = nil;
    @try { panelView = [ball valueForKey:@"panelView"]; } @catch (...) {}
    if (!panelView) return;
    UIView *actionPage = [panelView viewWithTag:0x56435042];
    if (actionPage) actionPage.hidden = YES;
    UIView *licPage = [panelView viewWithTag:0x56435044];
    if (licPage) licPage.hidden = YES;
    UIButton *actTab = [panelView viewWithTag:0x56435041];
    if (actTab) actTab.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIButton *licTab = [panelView viewWithTag:0x56435043];
    if (licTab) licTab.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
}'''

k7_old = '''- (void)actionTabTapped {'''
k7_new = '''- (UIView *)buildLicensePage:(CGFloat)panelW tabControl:(UIButton *)tabControl {
    CGFloat pad = 10;
    CGFloat contentW = panelW - pad * 2;
    CGFloat pageTop = tabControl.frame.origin.y + tabControl.frame.size.height + 6;
    CGFloat labelH = 14;
    CGFloat rowH = 34;
    CGFloat statusH = 20;
    CGFloat tipH = 16;
    CGFloat gap = 10;
    CGFloat pageH = 12 + labelH + 4 + rowH + gap + labelH + 4 + rowH + gap + statusH + 4 + tipH + 12;

    UIView *page = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, pageH)];
    page.backgroundColor = [UIColor colorWithRed:0.22 green:0.23 blue:0.25 alpha:1.0];
    CGFloat y = 12;

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, contentW, labelH)];
    l1.text = @"设备码";
    l1.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    l1.font = [UIFont systemFontOfSize:12];
    [page addSubview:l1];
    y += labelH + 4;

    CGFloat copyW = 60;
    CGFloat codeW = contentW - copyW - 8;
    UIView *codeBox = [[UIView alloc] initWithFrame:CGRectMake(pad, y, codeW, rowH)];
    codeBox.backgroundColor = [UIColor colorWithRed:0.18 green:0.19 blue:0.21 alpha:1.0];
    codeBox.layer.cornerRadius = 6;
    UILabel *codeLbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, codeW - 16, rowH)];
    codeLbl.text = vclp_DeviceCode();
    codeLbl.textColor = [UIColor whiteColor];
    codeLbl.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    codeLbl.adjustsFontSizeToFitWidth = YES;
    codeLbl.minimumScaleFactor = 0.7;
    [codeBox addSubview:codeLbl];
    [page addSubview:codeBox];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(pad + codeW + 8, y, copyW, rowH);
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    copyBtn.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:1.0];
    copyBtn.layer.cornerRadius = 6;
    [copyBtn addTarget:self action:@selector(copyDeviceCode:) forControlEvents:UIControlEventTouchUpInside];
    [page addSubview:copyBtn];
    y += rowH + gap;

    UIView *activateSection = [[UIView alloc] initWithFrame:CGRectMake(0, y, panelW, labelH + 4 + rowH)];
    activateSection.tag = 0x56435045;
    activateSection.backgroundColor = [UIColor clearColor];
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(pad, 0, contentW, labelH)];
    l2.text = @"卡密";
    l2.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    l2.font = [UIFont systemFontOfSize:12];
    [activateSection addSubview:l2];

    CGFloat actW = 70;
    CGFloat inputW = contentW - actW - 8;
    _cardField = [[UITextField alloc] initWithFrame:CGRectMake(pad, labelH + 4, inputW, rowH)];
    _cardField.backgroundColor = [UIColor colorWithRed:0.18 green:0.19 blue:0.21 alpha:1.0];
    _cardField.textColor = [UIColor whiteColor];
    _cardField.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _cardField.placeholder = @"XXXX-XXXX-XXXX-XXXX";
    _cardField.layer.cornerRadius = 6;
    _cardField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _cardField.autocorrectionType = UITextAutocorrectionTypeNo;
    _cardField.spellCheckingType = UITextSpellCheckingTypeNo;
    UIView *lp = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, rowH)];
    _cardField.leftView = lp;
    _cardField.leftViewMode = UITextFieldViewModeAlways;
    [activateSection addSubview:_cardField];

    UIButton *actBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    actBtn.frame = CGRectMake(pad + inputW + 8, labelH + 4, actW, rowH);
    [actBtn setTitle:@"激活" forState:UIControlStateNormal];
    [actBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    actBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    actBtn.backgroundColor = [UIColor colorWithRed:0.36 green:0.42 blue:0.58 alpha:1.0];
    actBtn.layer.cornerRadius = 6;
    [actBtn addTarget:self action:@selector(activateTapped:) forControlEvents:UIControlEventTouchUpInside];
    [activateSection addSubview:actBtn];
    [page addSubview:activateSection];
    y += labelH + 4 + rowH + gap;

    _licenseStatusRow = [[UIView alloc] initWithFrame:CGRectMake(pad, y, contentW, statusH)];
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, (statusH-8)/2, 8, 8)];
    dot.layer.cornerRadius = 4;
    dot.tag = 0x56435046;
    [_licenseStatusRow addSubview:dot];
    _licenseStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, contentW - 14, statusH)];
    _licenseStatusLabel.font = [UIFont boldSystemFontOfSize:13];
    [_licenseStatusRow addSubview:_licenseStatusLabel];
    [page addSubview:_licenseStatusRow];
    y += statusH + 4;

    _licenseDetailLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, contentW, tipH)];
    _licenseDetailLabel.font = [UIFont systemFontOfSize:11];
    _licenseDetailLabel.textColor = [UIColor colorWithRed:0.62 green:0.63 blue:0.65 alpha:1.0];
    _licenseDetailLabel.adjustsFontSizeToFitWidth = YES;
    [page addSubview:_licenseDetailLabel];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshLicenseUI]; });
    return page;
}

- (void)refreshLicenseUI {
    if (!_licenseStatusRow) return;
    BOOL activated = vclp_IsActivated();
    UIView *dot = [_licenseStatusRow viewWithTag:0x56435046];
    UIView *actSec = [_licensePage viewWithTag:0x56435045];
    if (actSec) actSec.hidden = activated;

    if (activated) {
        dot.backgroundColor = [UIColor colorWithRed:0.18 green:0.80 blue:0.44 alpha:1.0];
        _licenseStatusLabel.text = @"✓ 已激活";
        _licenseStatusLabel.textColor = [UIColor colorWithRed:0.18 green:0.80 blue:0.44 alpha:1.0];
        if (gVclpExpireAt == 0) {
            _licenseDetailLabel.text = @"有效期：永久";
        } else {
            NSDate *exp = [NSDate dateWithTimeIntervalSince1970:gVclpExpireAt];
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd";
            NSInteger days = (NSInteger)([exp timeIntervalSinceNow] / 86400.0);
            _licenseDetailLabel.text = [NSString stringWithFormat:@"到期时间：%@   剩余 %ld 天",
                                        [fmt stringFromDate:exp], (long)MAX(days, 0)];
        }
    } else {
        dot.backgroundColor = [UIColor colorWithRed:0.91 green:0.30 blue:0.24 alpha:1.0];
        _licenseStatusLabel.text = @"● 未激活";
        _licenseStatusLabel.textColor = [UIColor colorWithRed:0.91 green:0.30 blue:0.24 alpha:1.0];
        _licenseDetailLabel.text = @"请把上方设备码发给作者获取卡密";
    }
}

- (void)copyDeviceCode:(UIButton *)sender {
    [UIPasteboard generalPasteboard].string = vclp_DeviceCode();
    [sender setTitle:@"已复制" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [sender setTitle:@"复制" forState:UIControlStateNormal];
    });
}

- (void)activateTapped:(UIButton *)sender {
    NSString *input = _cardField.text ?: @"";
    if (input.length == 0) {
        [self showLicenseAlert:@"请输入卡密" msg:@"请把设备码发给作者获取卡密"];
        return;
    }
    if (!vclp_Verify(input)) {
        [self showLicenseAlert:@"卡密无效" msg:@"请检查卡密是否正确，或联系作者"];
        CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        shake.values = @[@(-8), @(8), @(-6), @(6), @(-3), @(3), @0];
        shake.duration = 0.4;
        [_cardField.layer addAnimation:shake forKey:@"shake"];
        return;
    }
    vclp_SetActivated(YES);
    vclp_Save(input);
    [self refreshLicenseUI];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"激活成功"
        message:@"功能已解锁" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = [self findRootVC];
    if (root) [root presentViewController:a animated:YES completion:nil];
}

- (void)showLicenseAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = [self findRootVC];
    if (root) [root presentViewController:a animated:YES completion:nil];
}

- (void)licenseTabTapped {
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
    if (!_licensePage || !_licenseTabBtn) return;

    controlPage.hidden = YES;
    if (lightPage) lightPage.hidden = YES;
    if (actionPage) actionPage.hidden = YES;
    _licensePage.hidden = NO;

    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    UIColor *active = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
    if (controlTab) controlTab.backgroundColor = inactive;
    if (lightTab) lightTab.backgroundColor = inactive;
    if (actionTab) actionTab.backgroundColor = inactive;
    _licenseTabBtn.backgroundColor = active;

    [self refreshLicenseUI];

    CGFloat pageTop = _licensePage.frame.origin.y;
    CGFloat targetH = pageTop + _licensePage.frame.size.height + 10;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = panelView.frame;
        f.size.height = targetH;
        panelView.frame = f;
    }];
}

- (void)actionTabTapped {'''

k8_old = '''- (void)selectVideoTapped {
    if (!NSClassFromString(@"PHPickerViewController")) return;'''
k8_new = '''extern BOOL vclp_IsActivated_External(void);

- (void)selectVideoTapped {
    if (!vclp_IsActivated_External()) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"未激活"
            message:@"请先在「验证」页输入卡密激活" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"去激活" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *act) {
                Class cls = NSClassFromString(@"VCamActionPatch");
                if (cls) {
                    SEL sShared = NSSelectorFromString(@"shared");
                    SEL sTab = NSSelectorFromString(@"licenseTabTapped");
                    if ([cls respondsToSelector:sShared]) {
                        id (*fnShared)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:sShared];
                        id patch = fnShared(cls, sShared);
                        if (patch && [patch respondsToSelector:sTab]) {
                            ((void(*)(id,SEL))[patch methodForSelector:sTab])(patch, sTab);
                        }
                    }
                }
            }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *root = self.overlayWindow.rootViewController;
        if (root) [root presentViewController:a animated:YES completion:nil];
        return;
    }
    if (!NSClassFromString(@"PHPickerViewController")) return;'''

k9_old = '''- (void)doAction:(int)action {
    int tk = VCAP_GetInt(kTokenKey, 0) + 1;'''
k9_new = '''- (void)doAction:(int)action {
    if (!vclp_IsActivated()) return;
    int tk = VCAP_GetInt(kTokenKey, 0) + 1;'''

k10_old = '''- (void)editTime:(int)which {
    NSString *name = @"";'''
k10_new = '''- (void)editTime:(int)which {
    if (!vclp_IsActivated()) return;
    NSString *name = @"";'''

k11_old = '''- (void)resetAll {
    VCAP_SetDict(@{'''
k11_new = '''- (void)resetAll {
    if (!vclp_IsActivated()) return;
    VCAP_SetDict(@{'''

k12_old = '''- (void)actionTabTapped {
    id ball = VCAP_FindBallInstance();
    if (!ball) return;

    UIView *panelView = nil, *controlPage = nil, *lightPage = nil;
    UIButton *controlTab = nil, *lightTab = nil;'''
k12_new = '''- (void)actionTabTapped {
    if (_licensePage) _licensePage.hidden = YES;
    if (_licenseTabBtn) _licenseTabBtn.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
    id ball = VCAP_FindBallInstance();
    if (!ball) return;

    UIView *panelView = nil, *controlPage = nil, *lightPage = nil;
    UIButton *controlTab = nil, *lightTab = nil;'''


# ============================================================
# [16] VCamFloatingBall.m — 控制页锁死
# ============================================================
fb_helper_old = '''// 禁用视频 / 启用视频 (替/原)
- (void)toggleReplacementTapped {'''
fb_helper_new = '''// 禁用视频 / 启用视频 (替/原)
- (void)toggleReplacementTapped {
    if (!vclp_IsActivated_External()) return;'''

fb_rotate_old = '''// 旋转 90°(顺时针, 以 plist 为单一事实源)
- (void)rotateRightTapped {'''
fb_rotate_new = '''// 旋转 90°(顺时针, 以 plist 为单一事实源)
- (void)rotateRightTapped {
    if (!vclp_IsActivated_External()) return;'''

fb_zin_old = '''- (void)zoomInTapped {
    double nz = vcamClamp([VCamNotify plistZoom] * vcamTZoomFactor(),'''
fb_zin_new = '''- (void)zoomInTapped {
    if (!vclp_IsActivated_External()) return;
    double nz = vcamClamp([VCamNotify plistZoom] * vcamTZoomFactor(),'''

fb_zout_old = '''- (void)zoomOutTapped {
    double nz = vcamClamp([VCamNotify plistZoom] / vcamTZoomFactor(),'''
fb_zout_new = '''- (void)zoomOutTapped {
    if (!vclp_IsActivated_External()) return;
    double nz = vcamClamp([VCamNotify plistZoom] / vcamTZoomFactor(),'''


# ============================================================
# [17] VCamFloatingBall.m — cellH 52 → 42
# ============================================================
cell_old = "CGFloat cellH = 52;"
cell_new = "CGFloat cellH = 42;"


def main():
    ok = True
    ok &= patch_file("VCamCore.m", c962_old, c962_new, "c962-syntax")
    ok &= patch_file("VcamFix.m", vf_old, vf_new, "path-mtime")
    ok &= patch_file("VcamFix.m", vc_old, vc_new, "cache-core-class")
    ok &= patch_file("VcamFix.m", vb_old, vb_new, "cache-ball-class")
    ok &= patch_file("VcamFix.m", vr_old, vr_new, "read-enabled-mtime")
    ok &= patch_file("VcamFix.m", vs_old, vs_new, "syncenabled-ivar-cache")
    ok &= patch_file("VcamFix.m", vt_old, vt_new, "merge-timers")
    ok &= patch_file("VcamFix.m", hb_old, hb_new, "hidebtn-size")
    ok &= patch_file("VcamFix.m", f1_old, f1_new, "disable-cpu-crop")
    ok &= patch_file("VCamCore.m", cp_old, cp_new, "polling-0.5s")
    ok &= patch_file("VCamCore.m", cs_old, cs_new, "scan-120s")
    ok &= patch_file("VCamCore.m", cpr_old, cpr_new, "prerender-idle-0.5s")
    ok &= patch_file("LocalVideoPlayer.m", ld_old, ld_new, "decode-idle-0.5s")
    ok &= patch_file("Tweak.m", ph_helper_old, ph_helper_new, "photo-srgb")
    ok &= patch_file("Tweak.m", ph_hook_old, ph_hook_new, "photo-force-srgb")
    ok &= patch_file("VCamActionPatch.m", k1_old, k1_new, "license-core")
    ok &= patch_file("VCamActionPatch.m", k2_old, k2_new, "license-init")
    ok &= patch_file("VCamActionPatch.m", k3_old, k3_new, "license-interface")
    ok &= patch_file("VCamActionPatch.m", k4_old, k4_new, "license-ivars")
    ok &= patch_file("VCamActionPatch.m", k5_old, k5_new, "tab-3width-noexpand")
    ok &= patch_file("VCamActionPatch.m", k5_old2, k5_new2, "tab-license-page")
    ok &= patch_file("VCamActionPatch.m", k6_old, k6_new, "hide-all-pages")
    ok &= patch_file("VCamActionPatch.m", k7_old, k7_new, "license-page-ui")
    ok &= patch_file("VCamFloatingBall.m", k8_old, k8_new, "lock-select-video")
    ok &= patch_file("VCamActionPatch.m", k9_old, k9_new, "lock-doAction")
    ok &= patch_file("VCamActionPatch.m", k10_old, k10_new, "lock-editTime")
    ok &= patch_file("VCamActionPatch.m", k11_old, k11_new, "lock-resetAll")
    ok &= patch_file("VCamActionPatch.m", k12_old, k12_new, "hide-license-on-action")
    ok &= patch_file("VCamFloatingBall.m", fb_helper_old, fb_helper_new, "lock-toggle")
    ok &= patch_file("VCamFloatingBall.m", fb_rotate_old, fb_rotate_new, "lock-rotate")
    ok &= patch_file("VCamFloatingBall.m", fb_zin_old, fb_zin_new, "lock-zoomin")
    ok &= patch_file("VCamFloatingBall.m", fb_zout_old, fb_zout_new, "lock-zoomout")
    ok &= patch_file("VCamFloatingBall.m", cell_old, cell_new, "cellH-42")

    if not ok:
        print("!! apply_all 有未匹配项", file=sys.stderr)
        sys.exit(1)
    print(">> apply_all 完成")


if __name__ == "__main__":
    main()
