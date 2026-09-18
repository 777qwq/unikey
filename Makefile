export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:26.5:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UniKey UniKeyApp
UniKey_FILES = UniKey.x
UniKey_FRAMEWORKS = UIKit QuartzCore
UniKey_LDFLAGS = -undefined dynamic_lookup
UniKey_CFLAGS = -fobjc-arc

UniKeyApp_FILES = UniKeyApp.x
UniKeyApp_FRAMEWORKS = UIKit QuartzCore
UniKeyApp_LDFLAGS = -undefined dynamic_lookup
UniKeyApp_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
