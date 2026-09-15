#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_fix4.py — 拍照色彩修复（源码零改动）

根因：src/dst 同格式（420f→420f）时 VT 直接逐字节拷贝，不做范围/矩阵转换，
      导致 video range 数据被按 full range 解读，拍照过饱和、偏橙、绿色荧光。

修复：在 VTPixelTransferSessionTransferImage 前，从 dst 读取色彩附件，
      设为 VT session 的 Destination* 属性，强制 VT 做正确转换。

用法：仓库根目录执行
    python3 apply_fix4.py
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
# [1] 在文件顶部加一个 helper（放在 vcamSyncColorAttachments 后面）
# ============================================================
helper_anchor = '''static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {'''
helper_code = '''static void vcamApplyDestinationColorProps(CFTypeRef session, CVPixelBufferRef dst) {
    if (!session || !dst) return;
    CFTypeRef m = CVBufferGetAttachment(dst, kCVImageBufferYCbCrMatrixKey, NULL);
    if (m) {
        VTSessionSetProperty(session, CFSTR("DestinationYCbCrMatrix"), m);
    }
    CFTypeRef p = CVBufferGetAttachment(dst, kCVImageBufferColorPrimariesKey, NULL);
    if (p) {
        VTSessionSetProperty(session, CFSTR("DestinationColorPrimaries"), p);
    }
    CFTypeRef tf = CVBufferGetAttachment(dst, kCVImageBufferTransferFunctionKey, NULL);
    if (tf) {
        VTSessionSetProperty(session, CFSTR("DestinationTransferFunction"), tf);
    }
}

static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {'''

# ============================================================
# [2] 私有格式车道（!isBgraLane && !isYuvLane），传输前设置目标属性
# ============================================================
priv_old = '''    if (!isBgraLane && !isYuvLane) {
        [_laneLockPrivate lock];
        BOOL ok = vcamPrivateLaneTransfer(self, src, dst, token);
        [_laneLockPrivate unlock];'''

priv_new = '''    if (!isBgraLane && !isYuvLane) {
        [_laneLockPrivate lock];
        VTPixelTransferSessionRef psess = self.privateTransferSession;
        if (psess) vcamApplyDestinationColorProps((CFTypeRef)psess, dst);
        BOOL ok = vcamPrivateLaneTransfer(self, src, dst, token);
        [_laneLockPrivate unlock];'''

# ============================================================
# [3] 标准 YUV/BGRA 车道，传输前设置目标属性
# ============================================================
std_old = '''    if (!session || !laneLock) return NO;

    [laneLock lock];

    // ★ 绿边修复 (标准 YUV 车道): BGRA 源 → YUV420 dst 且 Trim crop offset 非整数'''

std_new = '''    if (!session || !laneLock) return NO;

    [laneLock lock];

    // ★ 色彩修复：把 dst 的色彩附件设成 VT session 目标属性，
    //   强制 VT 做 601/709 与 video/full range 的转换
    vcamApplyDestinationColorProps((CFTypeRef)session, dst);

    // ★ 绿边修复 (标准 YUV 车道): BGRA 源 → YUV420 dst 且 Trim crop offset 非整数'''

# ============================================================
# [4] normal session（绿边修复路径）也要设置目标属性
# ============================================================
norm_old = '''            if (cropped) {
                VTPixelTransferSessionRef ns = [self normalTransferSession];
                if (ns) {
                    xferSrc = cropped;
                    xferSess = ns;'''

norm_new = '''            if (cropped) {
                VTPixelTransferSessionRef ns = [self normalTransferSession];
                if (ns) {
                    vcamApplyDestinationColorProps((CFTypeRef)ns, dst);
                    xferSrc = cropped;
                    xferSess = ns;'''


def main():
    ok = True
    # helper：靠 vcamSyncColorAttachments 定义行做锚点插入
    try:
        with open("GPUImageProcessor.m", "r", encoding="utf-8") as f:
            content = f.read()
        if "vcamApplyDestinationColorProps" in content:
            print(">> 已应用过，跳过: GPUImageProcessor.m [helper]")
        else:
            if helper_anchor not in content:
                print("!! 未匹配: GPUImageProcessor.m [helper-anchor]", file=sys.stderr)
                ok = False
            else:
                content = content.replace(helper_anchor, helper_code, 1)
                with open("GPUImageProcessor.m", "w", encoding="utf-8") as f:
                    f.write(content)
                print(">> 已修改: GPUImageProcessor.m [helper]")
    except FileNotFoundError:
        print("!! 文件不存在: GPUImageProcessor.m", file=sys.stderr)
        ok = False

    ok &= patch_file("GPUImageProcessor.m", priv_old, priv_new, "priv-lane")
    ok &= patch_file("GPUImageProcessor.m", std_old, std_new, "std-lane")
    ok &= patch_file("GPUImageProcessor.m", norm_old, norm_new, "normal-session")

    if not ok:
        print("!! apply_fix4 有未匹配项", file=sys.stderr)
        sys.exit(1)
    print(">> apply_fix4 完成")


if __name__ == "__main__":
    main()
