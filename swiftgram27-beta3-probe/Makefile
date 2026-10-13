ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = Swiftgram27Beta3Probe
Swiftgram27Beta3Probe_FILES = Probe.m
Swiftgram27Beta3Probe_FRAMEWORKS = Foundation UIKit
Swiftgram27Beta3Probe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
Swiftgram27Beta3Probe_LDFLAGS = -Wl,-install_name,@rpath/Swiftgram27Beta3Probe.dylib
Swiftgram27Beta3Probe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
