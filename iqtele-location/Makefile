ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQTeleLocation

iQTeleLocation_FILES = Tweak.m
iQTeleLocation_FRAMEWORKS = Foundation UIKit CoreLocation MapKit
iQTeleLocation_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-deprecated-declarations -Wno-sign-compare
iQTeleLocation_LDFLAGS = -Wl,-install_name,@rpath/iQTeleLocation.dylib
iQTeleLocation_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
