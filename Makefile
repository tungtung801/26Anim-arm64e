TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

INSTALL_TARGET_PROCESSED = YES

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = 26Anim
26Anim_FILES = Tweak.x
26Anim_FRAMEWORKS = UIKit QuartzCore Foundation
26Anim_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function
26Anim_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
