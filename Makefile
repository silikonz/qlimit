TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = powerd
ARCHS = arm64 arm64e



include $(THEOS)/makefiles/common.mk

TWEAK_NAME = qlimit

qlimit_FILES = Tweak.xm libsmc.c
qlimit_CFLAGS = -fobjc-arc
qlimit_FRAMEWORKS = Foundation CoreFoundation IOKit


include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += qlimitprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
