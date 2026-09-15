#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_fix2.py — 构建时注入补丁（不改源仓库文件）
问题1：换视频后旧视频残留约 1 秒
问题2：拍照/录像与原视频色差大

用法：在仓库根目录执行
    python3 apply_fix2.py
幂等：重复执行不会报错。
"""
import sys

def patch_file(path, old, new, tag):
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        print(f"!! 文件不存在: {path}", file=sys.stderr)
        return False

    if new.strip() in content and old not in content:
        print(f">> 已应用过，跳过: {path} [{tag}]")
        return True

    if old not in content:
        print(f"!! 未匹配到目标片段: {path} [{tag}]", file=sys.stderr)
        return False

    content = content.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f">> 已修改: {path} [{tag}]")
    return True


# ============================================================
# 补丁 1: VcamFix.m — 文件内容变化检测（mtime/size）
# ============================================================
vcamfix_old = '''        if (gLastActivePath == nil) {
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

vcamfix_new = '''        if (gLastActivePath == nil) {
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
# 补丁 2: GPUImageProcessor.m — 私有格式车道，同步颜色附件
# ============================================================
gpu_old_1 = '''        if (ok) {
            vcamLaneNoteSuccess((uint32_t)dstFormat);'''

gpu_new_1 = '''        if (ok) {
            vcamSyncColorAttachments(src, dst);
            vcamLaneNoteSuccess((uint32_t)dstFormat);'''


# ============================================================
# 补丁 3: GPUImageProcessor.m — 标准 YUV/BGRA 车道，同步颜色附件
# ============================================================
gpu_old_2 = '''    if (status == noErr) {
        vcamLaneNoteSuccess((uint32_t)dstFormat);'''

gpu_new_2 = '''    if (status == noErr) {
        vcamSyncColorAttachments(src, dst);
        vcamLaneNoteSuccess((uint32_t)dstFormat);'''


def main():
    ok = True
    ok &= patch_file("VcamFix.m", vcamfix_old, vcamfix_new, "path-mtime")
    ok &= patch_file("GPUImageProcessor.m", gpu_old_1, gpu_new_1, "color-private")
    ok &= patch_file("GPUImageProcessor.m", gpu_old_2, gpu_new_2, "color-yuv")

    if not ok:
        print("!! apply_fix2 失败", file=sys.stderr)
        sys.exit(1)
    print(">> apply_fix2 完成")


if __name__ == "__main__":
    main()
