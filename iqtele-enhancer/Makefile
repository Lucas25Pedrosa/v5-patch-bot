ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQTeleEnhancer

iQTeleEnhancer_FILES = Tweak.m SupportSuppress.m
iQTeleEnhancer_FRAMEWORKS = Foundation UIKit QuartzCore
iQTeleEnhancer_CFLAGS = -fobjc-arc -Wall -Wextra
iQTeleEnhancer_LDFLAGS = -Wl,-install_name,@rpath/iQTeleEnhancer.dylib
iQTeleEnhancer_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
