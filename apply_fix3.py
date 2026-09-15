#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_fix3.py — 构建时注入：发热 + 卡顿修复（源码零改动）

修复项：
  [发热]
   1. VcamFix_CoreClass / VcamFix_BallClass 加 dispatch_once 缓存
   2. VcamFix_ReadEnabled 加 mtime 缓存（不再 10Hz 解析 plist）
   3. VcamFix_SyncEnabled 缓存 Ivar（不再 10Hz 走 runtime 锁）
   4. 合并 gTimerMD + gTimerPath 双 timer → 单 timer，PathCheck 降为 0.5s
   5. VCamCore 轮询间隔 0.15s → 0.5s
   6. vcamNoLateHookLibs 扫描周期 30s → 120s
  [卡顿]
   7. LocalVideoPlayer.decodeLoop 空闲 sleep 0.1s → 0.5s
   8. VCamCore.startPrerenderThread 空闲 sleep 0.1s → 0.5s

用法：仓库根目录执行
    python3 apply_fix3.py
幂等：重复执行不报错。
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
# [1] VcamFix_CoreClass — 缓存
# ============================================================
p1_old = '''static Class VcamFix_CoreClass(void) {
    Class c = NSClassFromString(@"Qz1");
    return c ?: NSClassFromString(@"VCamCore");
}'''
p1_new = '''static Class VcamFix_CoreClass(void) {
    static Class c = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = NSClassFromString(@"Qz1") ?: NSClassFromString(@"VCamCore");
    });
    return c;
}'''


# ============================================================
# [2] VcamFix_BallClass — 缓存
# ============================================================
p2_old = '''static Class VcamFix_BallClass(void) {
    Class c = NSClassFromString(@"Jx6");
    return c ?: NSClassFromString(@"VCamFloatingBall");
}'''
p2_new = '''static Class VcamFix_BallClass(void) {
    static Class c = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = NSClassFromString(@"Jx6") ?: NSClassFromString(@"VCamFloatingBall");
    });
    return c;
}'''


# ============================================================
# [3] VcamFix_ReadEnabled — mtime 缓存（避免 10Hz 解析 plist）
# ============================================================
p3_old = '''static BOOL VcamFix_ReadEnabled(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:VcamFix_PlistPath()];
        if (d) return [d[@"enabled"] boolValue];
    } @catch (...) {}
    return NO;
}'''
p3_new = '''static BOOL VcamFix_ReadEnabled(void) {
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
# [4] VcamFix_SyncEnabled — 缓存 Ivar
# ============================================================
p4_old = '''static void VcamFix_SyncEnabled(void) {
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

p4_new = '''static void VcamFix_SyncEnabled(void) {
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
# [5] VcamFixInit — 合并 gTimerMD + gTimerPath
# ============================================================
p5_old = '''            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

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

p5_new = '''            dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

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
# [6] VCamCore.m — 轮询间隔 0.15s → 0.5s
# ============================================================
p6_old = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.15 callback:^(BOOL enabled) {'''
p6_new = '''    [[VCamNotify sharedInstance] startPollingWithInterval:0.5 callback:^(BOOL enabled) {'''


# ============================================================
# [7] VCamCore.m — 反注入扫描 30s → 120s
# ============================================================
p7_old = '''    if (snapshot && now - lastScan < 30.0) return lastRes;'''
p7_new = '''    if (snapshot && now - lastScan < 120.0) return lastRes;'''


# ============================================================
# [8] LocalVideoPlayer.m — decodeLoop 空闲 sleep 0.1s → 0.5s
# ============================================================
p8_old = '''                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // 加载代数变化 → 解码线程自行重建 reader'''

p8_new = '''                    [NSThread sleepForTimeInterval:0.5];
                    continue;
                }

                // 加载代数变化 → 解码线程自行重建 reader'''


# ============================================================
# [9] VCamCore.m — prerender 空闲 sleep 0.1s → 0.5s
# ============================================================
p9_old = '''                if (strongSelf.pipelineIdle) {
                    [NSThread sleepForTimeInterval:0.1];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }'''

p9_new = '''                if (strongSelf.pipelineIdle) {
                    [NSThread sleepForTimeInterval:0.5];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }'''


def main():
    ok = True
    ok &= patch_file("VcamFix.m", p1_old, p1_new, "cache-core-class")
    ok &= patch_file("VcamFix.m", p2_old, p2_new, "cache-ball-class")
    ok &= patch_file("VcamFix.m", p3_old, p3_new, "read-enabled-mtime")
    ok &= patch_file("VcamFix.m", p4_old, p4_new, "syncenabled-ivar-cache")
    ok &= patch_file("VcamFix.m", p5_old, p5_new, "merge-timers")
    ok &= patch_file("VCamCore.m", p6_old, p6_new, "polling-0.5s")
    ok &= patch_file("VCamCore.m", p7_old, p7_new, "scan-120s")
    ok &= patch_file("LocalVideoPlayer.m", p8_old, p8_new, "decode-idle-0.5s")
    ok &= patch_file("VCamCore.m", p9_old, p9_new, "prerender-idle-0.5s")

    if not ok:
        print("!! apply_fix3 有未匹配项", file=sys.stderr)
        sys.exit(1)
    print(">> apply_fix3 完成")


if __name__ == "__main__":
    main()
