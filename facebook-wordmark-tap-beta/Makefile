ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FacebookWordmarkTapBeta

FacebookWordmarkTapBeta_FILES = Tweak.m
FacebookWordmarkTapBeta_FRAMEWORKS = Foundation UIKit
FacebookWordmarkTapBeta_CFLAGS = -fobjc-arc -Wall -Wextra
FacebookWordmarkTapBeta_LDFLAGS = -Wl,-install_name,@rpath/FacebookWordmarkTapBeta.dylib
FacebookWordmarkTapBeta_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
