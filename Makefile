#############################################################################
# VcamMax — Rootless Theos Tweak Makefile
#
# 说明:
#   - 本 Makefile 只负责编译 dylib 到 .theos/obj/VcamMax.dylib (fat, arm64 + arm64e)
#   - deb 打包由 build.sh 手工完成 (rootless 布局: Library/... 无 rootfs 前缀)
#   - 所有 .m 都显式列出, 新增源码必须同步加入 VcamMax_FILES
#############################################################################

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VcamMax

VcamMax_FILES = \
    Tweak.m \
    VCamCore.m \
    GPUImageProcessor.m \
    LocalVideoPlayer.m \
    NSQueue.m \
    VCamNotify.m \
    VCamFloatingBall.m \
    VCamHidePatch.m \
    VCamActionPatch.m \
    FixActionPlayback.m \
    FixLicGate.m \
    VcamFix.m

VcamMax_CFLAGS = \
    -fobjc-arc \
    -Wno-deprecated-declarations \
    -Wno-unused-variable \
    -Wno-unused-function \
    -Wno-unused-property-ivar \
    -Wno-objc-property-no-attribute \
    -Wno-nullability-completeness

VcamMax_FRAMEWORKS = \
    UIKit \
    Foundation \
    AVFoundation \
    CoreMedia \
    CoreVideo \
    CoreImage \
    CoreGraphics \
    ImageIO \
    PhotosUI \
    Security \
    SystemConfiguration \
    CoreTelephony \
    CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk
