ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQTeleSwiftgram27Fix

iQTeleSwiftgram27Fix_FILES = Fix.m
iQTeleSwiftgram27Fix_FRAMEWORKS = Foundation
iQTeleSwiftgram27Fix_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
iQTeleSwiftgram27Fix_LDFLAGS = -Wl,-install_name,@rpath/iQTeleSwiftgram27Fix.dylib

iQTeleSwiftgram27Fix_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
