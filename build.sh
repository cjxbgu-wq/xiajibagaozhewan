#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { printf "\033[1;36m>>> %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m!!! %s\033[0m\n" "$*" >&2; exit 1; }

# ============================================================
#  依赖自动安装（CI runner / 本地通用）
# ============================================================
[ -n "$THEOS" ] || die "未设置 \$THEOS"

# 确保 Homebrew 在 PATH（macos-14 runner 默认在 /opt/homebrew）
if ! command -v brew >/dev/null 2>&1; then
    for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$bp" ]; then
            eval "$("$bp" shellenv)"
            break
        fi
    done
fi

ensure_tool() {
    local tool="$1"
    local formula="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        say "$tool 已安装: $(command -v "$tool")"
        return 0
    fi
    if ! command -v brew >/dev/null 2>&1; then
        die "缺少 $tool 且无 brew，请手动安装"
    fi
    say "缺少 $tool，brew 安装 $formula ..."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install "$formula"
    command -v "$tool" >/dev/null 2>&1 || die "$tool 安装后仍不可用"
    say "$tool 安装完成: $(command -v "$tool")"
}

ensure_tool ldid       ldid
ensure_tool dpkg-deb   dpkg
ensure_tool dpkg       dpkg
ensure_tool fakeroot   fakeroot
ensure_tool python3    python3

# ============================================================
#  清理 + Theos 编译（rootless）
# ============================================================
say "清理旧构建"
make clean 2>/dev/null || true

say "Theos 编译 (FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless)"
make FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

# ============================================================
#  收集 dylib（arm64 / arm64e 两个 slice）
# ============================================================
ARM64_DYLIB=$(find .theos -name "VcamMax.dylib" -path "*/obj/arm64/*" | head -1)
ARM64E_DYLIB=$(find .theos -name "VcamMax.dylib" -path "*/obj/arm64e/*" | head -1)

if [ -z "$ARM64_DYLIB" ] && [ -z "$ARM64E_DYLIB" ]; then
    die "未找到 VcamMax.dylib（arm64/arm64e 均为空）"
fi

say "arm64  dylib: ${ARM64_DYLIB:-<none>}"
say "arm64e dylib: ${ARM64E_DYLIB:-<none>}"

mkdir -p artifact
FAT_DYLIB="artifact/VcamMax.dylib"

if [ -n "$ARM64_DYLIB" ] && [ -n "$ARM64E_DYLIB" ]; then
    say "lipo 合并 arm64 + arm64e"
    lipo -create "$ARM64_DYLIB" "$ARM64E_DYLIB" -output "$FAT_DYLIB"
elif [ -n "$ARM64E_DYLIB" ]; then
    say "仅 arm64e，直接拷贝"
    cp -f "$ARM64E_DYLIB" "$FAT_DYLIB"
else
    say "仅 arm64，直接拷贝"
    cp -f "$ARM64_DYLIB" "$FAT_DYLIB"
fi

say "strip 去本地符号"
strip -x "$FAT_DYLIB" 2>/dev/null || strip "$FAT_DYLIB" 2>/dev/null || true

say "ldid 重签名"
ldid -S "$FAT_DYLIB"

say "dylib 架构信息"
lipo -info "$FAT_DYLIB" || true

# ============================================================
#  组装 debroot（对齐 VcamPlus：Library/... 无 rootfs 前缀）
# ============================================================
say "组装 debroot（rootless 布局，与 VcamPlus 一致）"
DEBROOT="$PWD/.debroot"
rm -rf "$DEBROOT"
mkdir -p "$DEBROOT/DEBIAN"
mkdir -p "$DEBROOT/Library/MobileSubstrate/DynamicLibraries"

# dylib + plist
cp -f "$FAT_DYLIB" "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.dylib"
if [ -f VcamMax.plist ]; then
    cp -f VcamMax.plist "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist"
else
    say "警告: VcamMax.plist 缺失"
fi

chmod 0755 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.dylib"
[ -f "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist" ] && \
    chmod 0644 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist"

# ============================================================
#  DEBIAN 控制文件（有自定义则用自定义，没有则生成默认）
# ============================================================
if [ -f control ]; then
    say "使用仓库内 control"
    cp -f control "$DEBROOT/DEBIAN/control"
else
    say "生成默认 control"
    cat > "$DEBROOT/DEBIAN/control" <<'EOF'
Package: com.example.vcammax
Name: VcamMax
Version: 1.0.0
Architecture: iphoneos-arm64
Description: Camera replacement tweak (rootless)
Maintainer: vcammax
Author: vcammax
Section: Tweaks
Depends: mobilesubstrate
EOF
fi

if [ -f preinst ]; then
    cp -f preinst "$DEBROOT/DEBIAN/preinst"
else
    cat > "$DEBROOT/DEBIAN/preinst" <<'EOF'
#!/bin/bash
set -e
JR=$(/usr/bin/jbroot 2>/dev/null || echo "/var/jb")
mkdir -p "$JR/Library/MobileSubstrate/DynamicLibraries" 2>/dev/null || true
exit 0
EOF
fi

if [ -f postinst ]; then
    cp -f postinst "$DEBROOT/DEBIAN/postinst"
else
    cat > "$DEBROOT/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
JR=$(/usr/bin/jbroot 2>/dev/null || echo "/var/jb")
DYLIB="$JR/Library/MobileSubstrate/DynamicLibraries/VcamMax.dylib"

if [ -f /usr/bin/jb_ctl ]; then
    /usr/bin/jb_ctl trustcache add "$DYLIB" 2>/dev/null || true
elif [ -f /usr/bin/jbctl ]; then
    /usr/bin/jbctl trustcache add "$DYLIB" 2>/dev/null || true
fi

killall -9 SpringBoard 2>/dev/null || true
killall -9 mediaserverd 2>/dev/null || true
exit 0
EOF
fi

if [ -f postrm ]; then
    cp -f postrm "$DEBROOT/DEBIAN/postrm"
else
    cat > "$DEBROOT/DEBIAN/postrm" <<'EOF'
#!/bin/bash
set -e
killall -9 SpringBoard 2>/dev/null || true
killall -9 mediaserverd 2>/dev/null || true
exit 0
EOF
fi

# 行尾修正（dpkg 对维护脚本要求 LF）
for f in "$DEBROOT/DEBIAN/preinst" "$DEBROOT/DEBIAN/postinst" "$DEBROOT/DEBIAN/postrm" "$DEBROOT/DEBIAN/control"; do
    [ -f "$f" ] && sed -i '' $'s/\r$//' "$f" 2>/dev/null || true
done

chmod 0755 "$DEBROOT/DEBIAN"
chmod 0644 "$DEBROOT/DEBIAN/control"
chmod 0755 "$DEBROOT/DEBIAN/preinst" 2>/dev/null || true
chmod 0755 "$DEBROOT/DEBIAN/postinst" 2>/dev/null || true
chmod 0755 "$DEBROOT/DEBIAN/postrm"   2>/dev/null || true

# ============================================================
#  打包：gzip + 剥离所有目录条目（关键修复 Read-only file system）
# ============================================================
say "打包 deb（gzip + 剥离目录条目）"
RAW_DEB="VcamMax_raw.deb"
OUT_DEB="VcamMax_latest.deb"
rm -f "$RAW_DEB" "$OUT_DEB"

fakeroot dpkg-deb -Zgzip -b "$DEBROOT" "$RAW_DEB"

python3 - "$RAW_DEB" "$OUT_DEB" <<'PYEOF'
import sys, io, os, gzip, tarfile

src, dst = sys.argv[1], sys.argv[2]

def parse_ar(data):
    members, off = {}, 8
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[0:16].decode().strip()
        size = int(hdr[48:58].decode().strip())
        members[name.rstrip("/")] = data[off + 60:off + 60 + size]
        off += 60 + size + (size & 1)
    return members

def ar_member(name, body):
    hdr = (name.ljust(16).encode()
           + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
           + b"100644".ljust(8) + str(len(body)).encode().ljust(10) + b"`\n")
    out = hdr + body
    return out + (b"\n" if len(body) & 1 else b"")

def strip_dir_entries(tar_bytes):
    """剥离所有目录条目，只保留普通文件 / 符号链接 / 硬链接"""
    entries = []
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for m in tf.getmembers():
            if m.isdir():
                continue
            if m.issym() or m.islnk():
                entries.append((m, None))
                continue
            content = tf.extractfile(m).read()
            entries.append((m, content))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:", format=tarfile.GNU_FORMAT) as tf:
        for m, content in entries:
            m.mtime = 0
            if content is None:
                m.size = 0
                tf.addfile(m)
            else:
                m.size = len(content)
                tf.addfile(m, io.BytesIO(content))
    return buf.getvalue()

with open(src, "rb") as f:
    members = parse_ar(f.read())

# data.tar.* —— 剥离目录条目
data_key = next(k for k in members if k.startswith("data.tar"))
data_raw = members[data_key]
if data_key.endswith(".gz"):
    data_plain = gzip.decompress(data_raw)
elif data_key.endswith(".xz"):
    import lzma
    data_plain = lzma.decompress(data_raw)
elif data_key.endswith(".zst"):
    import subprocess
    data_plain = subprocess.check_output(["zstd", "-d", "-c"], input=data_raw)
else:
    raise SystemExit("不支持的 data.tar 压缩: " + data_key)

data_stripped = strip_dir_entries(data_plain)
data_gz = gzip.compress(data_stripped, mtime=0)

# control.tar.* —— 原样保留（维护脚本不能动）
ctrl_key = next(k for k in members if k.startswith("control.tar"))
ctrl_raw = members[ctrl_key]

deb = b"!<arch>\n"
deb += ar_member("debian-binary", b"2.0\n")
deb += ar_member("control.tar.gz", ctrl_raw if ctrl_key.endswith(".gz") else gzip.compress(ctrl_raw, mtime=0))
deb += ar_member("data.tar.gz", data_gz)

with open(dst, "wb") as f:
    f.write(deb)

print("OK %s (%d bytes), 目录条目已剥离" % (dst, len(deb)))
PYEOF

rm -f "$RAW_DEB"
rm -rf "$DEBROOT"

# ============================================================
#  校验
# ============================================================
SIZE=$(stat -f%z "$OUT_DEB" 2>/dev/null || stat -c%s "$OUT_DEB")
say "构建完成: $OUT_DEB (${SIZE} bytes)"

say "deb 内容校验（应无 drwxr-xr-x 目录行）"
dpkg-deb -c "$OUT_DEB" || true

say "deb 控制信息"
dpkg-deb -I "$OUT_DEB" || true

say "全部完成 ✅"
