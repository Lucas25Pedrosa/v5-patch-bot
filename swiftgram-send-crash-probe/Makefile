ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = SwiftgramSendCrashProbe

SwiftgramSendCrashProbe_FILES = Probe.m
SwiftgramSendCrashProbe_FRAMEWORKS = Foundation UIKit
SwiftgramSendCrashProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
SwiftgramSendCrashProbe_LDFLAGS = -Wl,-install_name,@rpath/SwiftgramSendCrashProbe.dylib
SwiftgramSendCrashProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
