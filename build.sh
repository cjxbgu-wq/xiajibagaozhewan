#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { printf "\033[1;36m>>> %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m!!! %s\033[0m\n" "$*" >&2; exit 1; }

[ -n "$THEOS" ] || die "未设置 \$THEOS"
command -v ldid >/dev/null || die "缺少 ldid"
command -v dpkg-deb >/dev/null || die "缺少 dpkg-deb (brew install dpkg)"
command -v fakeroot >/dev/null || die "缺少 fakeroot (brew install fakeroot)"

say "清理旧构建"
make clean 2>/dev/null || true

say "Theos 编译 (rootless)"
make FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

DYLIB=$(find .theos -name "VcamMax.dylib" -path "*/obj/*" | head -1)
[ -f "$DYLIB" ] || die "未找到 VcamMax.dylib"
say "dylib: $DYLIB"

say "重新签名"
ldid -S "$DYLIB"

# ============================================================
#  手动构建 deb（对齐 VcamPlus：Library/... 路径 + 剥离目录条目）
# ============================================================
say "手动构建 deb（rootless 布局，与 VcamPlus 一致）"

DEBROOT="$PWD/.debroot"
rm -rf "$DEBROOT"
mkdir -p "$DEBROOT/DEBIAN"
# 关键：不带 rootfs 前缀，直接用 Library/...
mkdir -p "$DEBROOT/Library/MobileSubstrate/DynamicLibraries"

cp -f "$DYLIB"                          "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.dylib"
cp -f VcamMax.plist                     "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist"

chmod 0755 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.dylib"
chmod 0644 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamMax.plist"

# DEBIAN 控制文件（下面第二节给内容）
cp -f control  "$DEBROOT/DEBIAN/control"
cp -f preinst  "$DEBROOT/DEBIAN/preinst"
cp -f postinst "$DEBROOT/DEBIAN/postinst"
cp -f postrm   "$DEBROOT/DEBIAN/postrm"

# 行尾 + 权限（dpkg 对维护脚本要求苛刻）
sed -i '' $'s/\r$//' "$DEBROOT/DEBIAN/preinst" "$DEBROOT/DEBIAN/postinst" "$DEBROOT/DEBIAN/postrm" "$DEBROOT/DEBIAN/control" 2>/dev/null || true
chmod 0755 "$DEBROOT/DEBIAN"
chmod 0644 "$DEBROOT/DEBIAN/control"
chmod 0755 "$DEBROOT/DEBIAN/preinst"
chmod 0755 "$DEBROOT/DEBIAN/postinst"
chmod 0755 "$DEBROOT/DEBIAN/postrm"

# gzip 打包 + 剥离目录条目（关键：见 postprocess_deb.py）
RAW_DEB="VcamMax_raw.deb"
fakeroot dpkg-deb -Zgzip -b "$DEBROOT" "$RAW_DEB"

python3 postprocess_deb.py "$RAW_DEB" VcamMax_latest.deb
rm -f "$RAW_DEB"
rm -rf "$DEBROOT"

SIZE=$(stat -f%z VcamMax_latest.deb 2>/dev/null || stat -c%s VcamMax_latest.deb)
say "构建完成: VcamMax_latest.deb (${SIZE} bytes)"

say "内容校验（应无目录行 drwxr-xr-x）"
dpkg-deb -c VcamMax_latest.deb
