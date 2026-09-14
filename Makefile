TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

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
    VCamActionPatch.m \
    FixActionPlayback.m \
    VCamHidePatch.m

VcamMax_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function

VcamMax_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage CoreGraphics
VcamMax_PRIVATE_FRAMEWORKS =
VcamMax_LIBRARIES =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 mediaserverd; killall -9 SpringBoard"
