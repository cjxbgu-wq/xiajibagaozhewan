#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_all.py — 唯一补丁脚本（源码零改动，幂等）

包含全部修复：
  [编译]  VCamCore.m 962 行 Objective-C 语法
  [问题1] 换视频后旧视频残留（VcamFix 文件 mtime 检测）
  [问题2] 拍照色差（清空相机色彩/HDR 附件，强制 SDR BT.709）
  [发热]  VcamFix 反射缓存 / plist mtime 缓存 / timer 合并
  [卡顿]  轮询间隔、扫描周期、空闲 sleep 拉长

用法：仓库根目录执行
    python3 apply_all.py
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
# [1] VCamCore.m — 962 行语法修复
# ============================================================
c962_old = '''NSString *replayPath = [strongSelf.videoPlayer currentVideoPath copy];'''
c962_new = '''NSString *replayPath = [[strongSelf.videoPlayer currentVideoPath] copy];'''


# ============================================================
# [2] VcamFix.m — 换视频残留修复（mtime/size 检测）
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

        // \\u2605 文件内容变化检测（路径不变、文件被覆盖的场景）
        static double sLastMtime = 0;
        static unsigned long long sLastSize = 0;
        static NSString *sWatchedPath = nil;
        if (![sWatchedPath isEqualToString:curPath]) {
            sWatchedPath = [curPath copy];
            sLastMtime = 0;
            sLastSize = 0;
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
# [6] VcamFix.m — SyncEnabled Ivar 缓存
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
    if (ivFc) fc = *(uint64_t *)((uint8_t *)(__bridge void *)player + ivar_getOffset(ivFc));'''

vs_new = '''static void VcamFix_SyncEnabled(void) {
    static Class sCls = NULL;
    static Ivar sIvMd = NULL, sIvG = NULL, sIvM = NULL, sIvEn = NULL, sIvLiveY = NULL;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        sCls = VcamFix_CoreClass();
        if (!sCls) return;
        sIvMd = class_getInstanceVariable(sCls, "_isMediaserverdProcess");
        sIvG = class_getInstanceVariable(sCls, "_licGate");
        sIvM = class_getInstanceVariable(sCls, "_licMark");
        sIvEn = class_getInstanceVariable(sCls, "_enabled");
        sIvLiveY = class_getInstanceVariable(sCls, "_liveYUVPixelBuffer");
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
    if (!plistEn || !cur) return;

    CVPixelBufferRef live = NULL;
    if (sIvLiveY) live = *(CVPixelBufferRef *)(base + ivar_getOffset(sIvLiveY));

    id player = nil;
    @try { player = [core valueForKey:@"videoPlayer"]; } @catch (...) {}
    if (!player) return;
    uint64_t fc = 0;
    Ivar ivFc = class_getInstanceVariable([player class], "_frameCount");
    if (!ivFc) ivFc = class_getInstanceVariable([player class], "frameCount");
    if (ivFc) fc = *(uint64_t *)((uint8_t *)(__bridge void *)player + ivar_getOffset(ivFc));'''


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

            // 合并：门禁刷(0.1s) + 换视频检测(0.5s)，单 timer
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
# [8] VCamCore.m — 轮询 0.15s → 0.5s
# ============================================================
cp_old = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.15 callback:^(BOOL enabled) {'''
cp_new = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.5 callback:^(BOOL enabled) {'''


# ============================================================
# [9] VCamCore.m — 反注入扫描 30s → 120s
# ============================================================
cs_old = '''    if (snapshot && now - lastScan < 30.0) return lastRes;'''
cs_new = '''    if (snapshot && now - lastScan < 120.0) return lastRes;'''


# ============================================================
# [10] VCamCore.m — prerender 空闲 sleep 0.1s → 0.5s
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
# [11] LocalVideoPlayer.m — decodeLoop 空闲 sleep 0.1s → 0.5s
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
# [12] Tweak.m — 拍照原彩 helper（清空附件 + SDR 709）
# ============================================================
ph_helper_old = '''static void (*orig_BWPhotoEncoderNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);'''

ph_helper_new = '''static void (*orig_BWPhotoEncoderNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);

// ★ 拍照原彩核心：清空相机附加的全部色彩/HDR 附件，只留 SDR BT.709
static void vcamPhotoForceSDR(CMSampleBufferRef sb) {
    if (!sb) return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;

    // 1. 清空 pixelBuffer 上所有附件
    static CFDictionaryRef sEmpty = NULL;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        sEmpty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                    &kCFTypeDictionaryKeyCallBacks,
                                    &kCFTypeDictionaryValueCallBacks);
    });
    if (sEmpty) CVBufferSetAttachments(pb, sEmpty, kCVAttachmentMode_ShouldPropagate);

    // 2. 只设置 SDR BT.709
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);

    // 3. 清空 sampleBuffer 的 sample attachments
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (atts && CFArrayGetCount(atts) > 0) {
        for (CFIndex i = 0; i < CFArrayGetCount(atts); i++) {
            CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(atts, i);
            if (d) CFDictionaryRemoveAllValues(d);
        }
    }
}'''


# ============================================================
# [13] Tweak.m — 拍照 hook 追加 vcamPhotoForceSDR
# ============================================================
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
                    [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer
                                                                         pts:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))];
                    vcamPhotoForceSDR(sampleBuffer);
                    static int sLog = 0;
                    if ((++sLog % 30) == 1) {
                        vcam_tweak_log([NSString stringWithFormat:
                            @"[vcam] photo forced SDR709 (log#%d) %zux%zu fmt=0x%x",
                            sLog,
                            CVPixelBufferGetWidth(pixelBuffer),
                            CVPixelBufferGetHeight(pixelBuffer),
                            (unsigned)CVPixelBufferGetPixelFormatType(pixelBuffer)]);
                    }
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


def main():
    ok = True
    # 编译修复
    ok &= patch_file("VCamCore.m", c962_old, c962_new, "c962-syntax")
    # 问题1：换视频残留
    ok &= patch_file("VcamFix.m", vf_old, vf_new, "path-mtime")
    # 发热：VcamFix 缓存 + timer 合并
    ok &= patch_file("VcamFix.m", vc_old, vc_new, "cache-core-class")
    ok &= patch_file("VcamFix.m", vb_old, vb_new, "cache-ball-class")
    ok &= patch_file("VcamFix.m", vr_old, vr_new, "read-enabled-mtime")
    ok &= patch_file("VcamFix.m", vs_old, vs_new, "syncenabled-ivar-cache")
    ok &= patch_file("VcamFix.m", vt_old, vt_new, "merge-timers")
    # 发热/卡顿：VCamCore + LocalVideoPlayer
    ok &= patch_file("VCamCore.m", cp_old, cp_new, "polling-0.5s")
    ok &= patch_file("VCamCore.m", cs_old, cs_new, "scan-120s")
    ok &= patch_file("VCamCore.m", cpr_old, cpr_new, "prerender-idle-0.5s")
    ok &= patch_file("LocalVideoPlayer.m", ld_old, ld_new, "decode-idle-0.5s")
    # 拍照原彩：先插 helper，再改 hook
    ok &= patch_file("Tweak.m", ph_helper_old, ph_helper_new, "photo-sdr-helper")
    ok &= patch_file("Tweak.m", ph_hook_old, ph_hook_new, "photo-force-sdr")

    if not ok:
        print("!! apply_all 有未匹配项", file=sys.stderr)
        sys.exit(1)
    print(">> apply_all 完成")


if __name__ == "__main__":
    main()
