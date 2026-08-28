ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = powerd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QLimit
QLimit_FILES = Tweak.xm
QLimit_CFLAGS = -fobjc-arc
QLimit_FRAMEWORKS = Foundation CoreFoundation IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += qlimitprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
