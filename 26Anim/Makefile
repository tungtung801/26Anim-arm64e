export TARGET = iphone:clang:16.5:15.0
# arm64  -> A11 and earlier
# arm64e -> A12 and later (PAC); dyld picks the matching slice automatically
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 26Anim

26Anim_FILES = Tweak.xm
26Anim_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
26Anim_FRAMEWORKS = UIKit QuartzCore CoreGraphics
# NOTE: intentionally NOT linking CydiaSubstrate.  Hooking is done with the
# ObjC runtime (class_addMethod / method_setImplementation) — see Tweak.xm.
# Same reasoning as 26Unlock: a substrate load-command reference can make the
# dylib fail dlopen() before its constructor runs, so the tweak looks
# installed but does nothing.

include $(THEOS_MAKE_PATH)/tweak.mk

include $(THEOS_MAKE_PATH)/aggregate.mk
