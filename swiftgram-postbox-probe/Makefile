ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = SwiftgramPostboxProbe

SwiftgramPostboxProbe_FILES = Probe.m
SwiftgramPostboxProbe_FRAMEWORKS = Foundation UIKit
SwiftgramPostboxProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
SwiftgramPostboxProbe_LDFLAGS = -Wl,-install_name,@rpath/SwiftgramPostboxProbe.dylib
SwiftgramPostboxProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
