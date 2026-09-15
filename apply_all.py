#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_all.py — 构建时注入所有补丁（源码零改动，幂等）

汇总以下修复：
  [编译]   VCamCore.m 962 行 Objective-C 语法
  [问题1]  换视频后旧视频残留（VcamFix 文件 mtime 检测）
  [问题2]  拍照/录像色差（VT Source/Destination 色彩属性 + 中间 buffer 附件）
  [发热]   VcamFix timer 合并、反射缓存、plist mtime 缓存
  [卡顿]   轮询间隔、扫描周期、空闲 sleep 拉长

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
# [P1] VCamCore.m — 962 行语法修复
# ============================================================
c962_old = '''NSString *replayPath = [strongSelf.videoPlayer currentVideoPath copy];'''
c962_new = '''NSString *replayPath = [[strongSelf.videoPlayer currentVideoPath] copy];'''


# ============================================================
# [P2] VcamFix.m — 换视频残留修复（mtime/size 检测）
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
# [P3] VcamFix.m — CoreClass 缓存
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
# [P4] VcamFix.m — BallClass 缓存
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
# [P5] VcamFix.m — ReadEnabled mtime 缓存
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
# [P6] VcamFix.m — SyncEnabled Ivar 缓存
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
# [P7] VcamFix.m — 合并 timer
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
# [P8] VCamCore.m — 轮询 0.15s → 0.5s
# ============================================================
cp_old = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.15 callback:^(BOOL enabled) {'''
cp_new = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.5 callback:^(BOOL enabled) {'''

# ============================================================
# [P9] VCamCore.m — 反注入扫描 30s → 120s
# ============================================================
cs_old = '''    if (snapshot && now - lastScan < 30.0) return lastRes;'''
cs_new = '''    if (snapshot && now - lastScan < 120.0) return lastRes;'''

# ============================================================
# [P10] VCamCore.m — prerender 空闲 sleep 0.1s → 0.5s
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
# [P11] LocalVideoPlayer.m — decodeLoop 空闲 sleep 0.1s → 0.5s
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
# [P12] GPUImageProcessor.m — 插入 3 个 helper（fix4 + fix5 合并）
# ============================================================
gh_anchor = '''static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {'''
gh_code = '''static void vcamCopyAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    CFDictionaryRef atts = CVBufferGetAttachments(src, kCVAttachmentMode_ShouldPropagate);
    if (atts) CVBufferSetAttachments(dst, atts, kCVAttachmentMode_ShouldPropagate);
}

static void vcamApplySourceColorProps(CFTypeRef session, CVPixelBufferRef src) {
    if (!session || !src) return;
    CFTypeRef m = CVBufferGetAttachment(src, kCVImageBufferYCbCrMatrixKey, NULL);
    if (m) VTSessionSetProperty(session, CFSTR("SourceYCbCrMatrix"), m);
    CFTypeRef p = CVBufferGetAttachment(src, kCVImageBufferColorPrimariesKey, NULL);
    if (p) VTSessionSetProperty(session, CFSTR("SourceColorPrimaries"), p);
    CFTypeRef tf = CVBufferGetAttachment(src, kCVImageBufferTransferFunctionKey, NULL);
    if (tf) VTSessionSetProperty(session, CFSTR("SourceTransferFunction"), tf);
}

static void vcamApplyDestinationColorProps(CFTypeRef session, CVPixelBufferRef dst) {
    if (!session || !dst) return;
    CFTypeRef m = CVBufferGetAttachment(dst, kCVImageBufferYCbCrMatrixKey, NULL);
    if (m) VTSessionSetProperty(session, CFSTR("DestinationYCbCrMatrix"), m);
    CFTypeRef p = CVBufferGetAttachment(dst, kCVImageBufferColorPrimariesKey, NULL);
    if (p) VTSessionSetProperty(session, CFSTR("DestinationColorPrimaries"), p);
    CFTypeRef tf = CVBufferGetAttachment(dst, kCVImageBufferTransferFunctionKey, NULL);
    if (tf) VTSessionSetProperty(session, CFSTR("DestinationTransferFunction"), tf);
}

static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {'''

# ============================================================
# [P13] GPUImageProcessor.m — rotateAndMirrorIfNeeded 同步附件
# ============================================================
gr_old = '''        if (dst) {
            CFTypeRef rotValue;
            if (total == 90)       rotValue = _rotationCW90Value;
            else if (total == 270) rotValue = _rotationCCW90Value;
            else                   rotValue = _rotation180Value;
            VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, rotValue);'''
gr_new = '''        if (dst) {
            vcamCopyAttachments(input, dst);
            CFTypeRef rotValue;
            if (total == 90)       rotValue = _rotationCW90Value;
            else if (total == 270) rotValue = _rotationCCW90Value;
            else                   rotValue = _rotation180Value;
            VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, rotValue);'''

# 镜像分支创建 buffer 后同步附件
gm_old = '''        CVPixelBufferRef created = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, fmt, NULL, &created) == noErr && created) {
            [self setPrerenderRotateBuffer:created atSlot:mslot];
            mb = created;
        } else {
            [self setPrerenderRotateBuffer:NULL atSlot:mslot];
        }'''
gm_new = '''        CVPixelBufferRef created = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, fmt, NULL, &created) == noErr && created) {
            vcamCopyAttachments(work, created);
            [self setPrerenderRotateBuffer:created atSlot:mslot];
            mb = created;
        } else {
            [self setPrerenderRotateBuffer:NULL atSlot:mslot];
        }'''

# ============================================================
# [P14] GPUImageProcessor.m — adaptiveRotateIfNeeded 同步附件
# ============================================================
ga_old = '''        OSStatus cc = CVPixelBufferCreate(kCFAllocatorDefault, srcH, srcW, fmt, NULL, &rotated);
        if (cc != noErr || !rotated) {
            [_rotationRenderLock unlock];
            return (CVPixelBufferRef)CVPixelBufferRetain(src);
        }'''
ga_new = '''        OSStatus cc = CVPixelBufferCreate(kCFAllocatorDefault, srcH, srcW, fmt, NULL, &rotated);
        if (cc != noErr || !rotated) {
            [_rotationRenderLock unlock];
            return (CVPixelBufferRef)CVPixelBufferRetain(src);
        }
        vcamCopyAttachments(src, rotated);'''

# ============================================================
# [P15] GPUImageProcessor.m — 私有格式车道 Source + Destination
# ============================================================
gp_old = '''    if (!isBgraLane && !isYuvLane) {
        [_laneLockPrivate lock];
        BOOL ok = vcamPrivateLaneTransfer(self, src, dst, token);
        [_laneLockPrivate unlock];'''
gp_new = '''    if (!isBgraLane && !isYuvLane) {
        [_laneLockPrivate lock];
        VTPixelTransferSessionRef psess = self.privateTransferSession;
        if (psess) {
            vcamApplySourceColorProps((CFTypeRef)psess, src);
            vcamApplyDestinationColorProps((CFTypeRef)psess, dst);
        }
        BOOL ok = vcamPrivateLaneTransfer(self, src, dst, token);
        [_laneLockPrivate unlock];'''

# ============================================================
# [P16] GPUImageProcessor.m — 标准 YUV/BGRA 车道 Source + Destination
# ============================================================
gs_old = '''    if (!session || !laneLock) return NO;

    [laneLock lock];

    // ★ 绿边修复 (标准 YUV 车道): BGRA 源 → YUV420 dst 且 Trim crop offset 非整数'''
gs_new = '''    if (!session || !laneLock) return NO;

    [laneLock lock];

    // ★ 色彩修复：同时告知 VT 源和目标的色彩空间
    vcamApplySourceColorProps((CFTypeRef)session, src);
    vcamApplyDestinationColorProps((CFTypeRef)session, dst);

    // ★ 绿边修复 (标准 YUV 车道): BGRA 源 → YUV420 dst 且 Trim crop offset 非整数'''

# ============================================================
# [P17] GPUImageProcessor.m — normal session 也设 Source + Destination
# ============================================================
gn_old = '''            if (cropped) {
                VTPixelTransferSessionRef ns = [self normalTransferSession];
                if (ns) {
                    xferSrc = cropped;
                    xferSess = ns;'''
gn_new = '''            if (cropped) {
                VTPixelTransferSessionRef ns = [self normalTransferSession];
                if (ns) {
                    vcamApplySourceColorProps((CFTypeRef)ns, cropped);
                    vcamApplyDestinationColorProps((CFTypeRef)ns, dst);
                    xferSrc = cropped;
                    xferSess = ns;'''


def main():
    ok = True

    # 顺序敏感：fix4 的 helper 必须先插，fix5 才能匹配
    # 1. 编译修复
    ok &= patch_file("VCamCore.m", c962_old, c962_new, "c962-syntax")
    # 2. 换视频残留
    ok &= patch_file("VcamFix.m", vf_old, vf_new, "path-mtime")
    # 3. 发热：VcamFix 缓存 + timer 合并
    ok &= patch_file("VcamFix.m", vc_old, vc_new, "cache-core-class")
    ok &= patch_file("VcamFix.m", vb_old, vb_new, "cache-ball-class")
    ok &= patch_file("VcamFix.m", vr_old, vr_new, "read-enabled-mtime")
    ok &= patch_file("VcamFix.m", vs_old, vs_new, "syncenabled-ivar-cache")
    ok &= patch_file("VcamFix.m", vt_old, vt_new, "merge-timers")
    # 4. 发热/卡顿：VCamCore + LocalVideoPlayer
    ok &= patch_file("VCamCore.m", cp_old, cp_new, "polling-0.5s")
    ok &= patch_file("VCamCore.m", cs_old, cs_new, "scan-120s")
    ok &= patch_file("VCamCore.m", cpr_old, cpr_new, "prerender-idle-0.5s")
    ok &= patch_file("LocalVideoPlayer.m", ld_old, ld_new, "decode-idle-0.5s")
    # 5. GPUImageProcessor：先插 helper
    try:
        with open("GPUImageProcessor.m", "r", encoding="utf-8") as f:
            content = f.read()
        if "vcamApplyDestinationColorProps" in content:
            print(">> 已应用过，跳过: GPUImageProcessor.m [helpers]")
        elif gh_anchor not in content:
            print("!! 未匹配: GPUImageProcessor.m [helpers]", file=sys.stderr)
            ok = False
        else:
            content = content.replace(gh_anchor, gh_code, 1)
            with open("GPUImageProcessor.m", "w", encoding="utf-8") as f:
                f.write(content)
            print(">> 已修改: GPUImageProcessor.m [helpers]")
    except FileNotFoundError:
        print("!! 文件不存在: GPUImageProcessor.m", file=sys.stderr)
        ok = False
    # 6. 中间 buffer 附件同步
    ok &= patch_file("GPUImageProcessor.m", gr_old, gr_new, "rotate-attach")
    ok &= patch_file("GPUImageProcessor.m", gm_old, gm_new, "mirror-attach")
    ok &= patch_file("GPUImageProcessor.m", ga_old, ga_new, "adaptive-attach")
    # 7. VT session Source/Destination
    ok &= patch_file("GPUImageProcessor.m", gp_old, gp_new, "priv-lane")
    ok &= patch_file("GPUImageProcessor.m", gs_old, gs_new, "std-lane")
    ok &= patch_file("GPUImageProcessor.m", gn_old, gn_new, "normal-session")

    if not ok:
        print("!! apply_all 有未匹配项", file=sys.stderr)
        sys.exit(1)
    print(">> apply_all 完成")


if __name__ == "__main__":
    main()
