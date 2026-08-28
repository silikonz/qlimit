TARGET := iphone:clang:latest:7.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = qlimitprefs

qlimitprefs_FILES = QLIRootListController.m
qlimitprefs_FRAMEWORKS = UIKit
qlimitprefs_PRIVATE_FRAMEWORKS = Preferences
qlimitprefs_INSTALL_PATH = /Library/PreferenceBundles
qlimitprefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
