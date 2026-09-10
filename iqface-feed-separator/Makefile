ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceFeedSeparator

iQFaceFeedSeparator_FILES = TweakBuild.m
iQFaceFeedSeparator_FRAMEWORKS = Foundation UIKit QuartzCore
iQFaceFeedSeparator_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
iQFaceFeedSeparator_LDFLAGS = -Wl,-install_name,@rpath/iQFaceFeedSeparator.dylib
iQFaceFeedSeparator_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
