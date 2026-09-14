#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { printf "\033[1;36m>>> %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m!!! %s\033[0m\n" "$*" >&2; exit 1; }

[ -n "$THEOS" ] || die "未设置 \$THEOS"
command -v ldid >/dev/null || die "缺少 ldid"

say "清理旧构建"
make clean 2>/dev/null || true

say "Theos 编译"
make FINALPACKAGE=1

DYLIB=$(find .theos -name "VcamMax.dylib" -path "*/obj/*" | head -1)
[ -f "$DYLIB" ] || die "未找到 VcamMax.dylib"
say "dylib: $DYLIB"

say "重新签名"
ldid -S "$DYLIB"

say "打包 deb"
make package FINALPACKAGE=1

RAW_DEB=$(find packages -name "*.deb" 2>/dev/null | head -1)
[ -f "$RAW_DEB" ] || RAW_DEB=$(find . -name "*.deb" -not -path "*/.theos/*" 2>/dev/null | head -1)
[ -f "$RAW_DEB" ] || die "未找到 deb 产物"

cp -f "$RAW_DEB" VcamMax_latest.deb

SIZE=$(stat -f%z VcamMax_latest.deb 2>/dev/null || stat -c%s VcamMax_latest.deb)
say "构建完成: VcamMax_latest.deb (${SIZE} bytes)"
