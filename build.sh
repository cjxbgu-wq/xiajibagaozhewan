#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { echo -e "\033[1;36m>>> $*\033[0m"; }
die() { echo -e "\033[1;31m!!! $*\033[0m" >&2; exit 1; }

# ============================================================
#  依赖自动安装（CI runner / 本地通用）
# ============================================================
[ -n "$THEOS" ] || die "未设置 \$THEOS"

if ! command -v brew >/dev/null 2>&1; then
    for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$bp" ] && eval "$("$bp" shellenv)" && break
    done
fi

ensure_tool() {
    local tool="$1" formula="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        say "$tool: $(command -v "$tool")"
        return 0
    fi
    command -v brew >/dev/null 2>&1 || die "缺少 $tool 且无 brew"
    say "安装 $tool ..."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install "$formula"
    command -v "$tool" >/dev/null 2>&1 || die "$tool 安装失败"
}

ensure_tool ldid      ldid
ensure_tool dpkg-deb  dpkg
ensure_tool fakeroot  fakeroot
ensure_tool python3   python3

# ============================================================
#  清理 + 编译
# ============================================================
say "清理"
make clean 2>/dev/null || true

say "Theos 编译 (rootless, arm64+arm64e)"
make FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

# ============================================================
#  收集 dylib（用 Theos 合并产物，避开 dSYM 陷阱）
# ============================================================
THEOS_FAT=".theos/obj/VcamMax.dylib"
[ -f "$THEOS_FAT" ] || die "未找到 Theos 合并产物: $THEOS_FAT"

say "Theos 产物: $THEOS_FAT"
lipo -info "$THEOS_FAT" || true

lipo -info "$THEOS_FAT" | grep -q arm64e || die "产物缺少 arm64e slice"

mkdir -p artifact
FAT_DYLIB="artifact/VcamMax.dylib"
cp -f "$THEOS_FAT" "$FAT_DYLIB"

say "strip 去本地符号"
strip -x "$FAT_DYLIB" 2>/dev/null || true

say "ldid 重签"
ldid -S "$FAT_DYLIB"

say "最终 dylib:"
lipo -info "$FAT_DYLIB"

# ============================================================
#  组装 debroot（rootless 布局：Library/... 无 rootfs 前缀）
# ============================================================
say "组装 debroot（对齐 VcamPlus：Library/... 无 rootfs）"
DEBROOT="$PWD/.debroot"
rm -rf "$DEBROOT"
mkdir -p "$DEBROOT/DEBIAN"
mkdir -p "$DEBROOT/Library/MobileSubstrate/DynamicLibraries"

cp -f "$FAT_DYLIB" "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.dylib"
[ -f VcamMax.plist ] && cp -f VcamMax.plist "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist"

chmod 0755 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.dylib"
[ -f "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist" ] && \
    chmod 0644 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist"

# ============================================================
#  DEBIAN 控制文件
# ============================================================
if [ -f control ]; then
    cp -f control "$DEBROOT/DEBIAN/control"
else
    cat > "$DEBROOT/DEBIAN/control" <<'EOF'
Package: com.example.vcammax
Name: VcamMax
Version: 1.0.0
Architecture: iphoneos-arm64e
Description: Camera replacement tweak (arm64e rootless)
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
[ -f /usr/bin/jb_ctl ] && /usr/bin/jb_ctl trustcache add "$DYLIB" 2>/dev/null || true
[ -f /usr/bin/jbctl ]  && /usr/bin/jbctl  trustcache add "$DYLIB" 2>/dev/null || true
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

for f in preinst postinst postrm control; do
    [ -f "$DEBROOT/DEBIAN/$f" ] && sed -i '' $'s/\r$//' "$DEBROOT/DEBIAN/$f" 2>/dev/null || true
done

chmod 0755 "$DEBROOT/DEBIAN"
chmod 0644 "$DEBROOT/DEBIAN/control"
[ -f "$DEBROOT/DEBIAN/preinst"  ] && chmod 0755 "$DEBROOT/DEBIAN/preinst"
[ -f "$DEBROOT/DEBIAN/postinst" ] && chmod 0755 "$DEBROOT/DEBIAN/postinst"
[ -f "$DEBROOT/DEBIAN/postrm"   ] && chmod 0755 "$DEBROOT/DEBIAN/postrm"

# ============================================================
#  打包：gzip + 剥离目录条目
# ============================================================
say "打包 deb（gzip + 剥目录条目）"
RAW_DEB="VcamMax_raw.deb"
OUT_DEB="VcamMax_latest.deb"
rm -f "$RAW_DEB" "$OUT_DEB"

fakeroot dpkg-deb -Zgzip -b "$DEBROOT" "$RAW_DEB"

python3 - "$RAW_DEB" "$OUT_DEB" <<'PYEOF'
import sys, io, gzip, tarfile

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

def strip_dir(tar_bytes):
    entries = []
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for m in tf.getmembers():
            if m.isdir():
                continue
            if m.issym() or m.islnk():
                entries.append((m, None)); continue
            entries.append((m, tf.extractfile(m).read()))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:", format=tarfile.GNU_FORMAT) as tf:
        for m, content in entries:
            m.mtime = 0
            if content is None:
                m.size = 0; tf.addfile(m)
            else:
                m.size = len(content); tf.addfile(m, io.BytesIO(content))
    return buf.getvalue()

with open(src, "rb") as f:
    members = parse_ar(f.read())

data_key = next(k for k in members if k.startswith("data.tar"))
data_raw = members[data_key]
data_plain = gzip.decompress(data_raw) if data_key.endswith(".gz") else data_raw
data_gz = gzip.compress(strip_dir(data_plain), mtime=0)

ctrl_key = next(k for k in members if k.startswith("control.tar"))
ctrl_raw = members[ctrl_key]

deb  = b"!<arch>\n"
deb += ar_member("debian-binary", b"2.0\n")
deb += ar_member("control.tar.gz", ctrl_raw if ctrl_key.endswith(".gz") else gzip.compress(ctrl_raw, mtime=0))
deb += ar_member("data.tar.gz", data_gz)

open(dst, "wb").write(deb)
print("OK %s (%d bytes), 目录条目已剥离" % (dst, len(deb)))
PYEOF

rm -f "$RAW_DEB"
rm -rf "$DEBROOT"

# ============================================================
#  校验
# ============================================================
SIZE=$(stat -f%z "$OUT_DEB" 2>/dev/null || stat -c%s "$OUT_DEB")
say "构建完成: $OUT_DEB (${SIZE} bytes)"

say "内容校验（应无 drwxr-xr-x 目录行）"
dpkg-deb -c "$OUT_DEB" || true

say "控制信息（Architecture 应为 iphoneos-arm64e）"
dpkg-deb -I "$OUT_DEB" || true

say "全部完成 ✅"
