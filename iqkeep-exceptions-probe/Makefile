ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQKeepDeletedExceptionsProbe

iQKeepDeletedExceptionsProbe_FILES = Probe.m
iQKeepDeletedExceptionsProbe_FRAMEWORKS = Foundation
iQKeepDeletedExceptionsProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
iQKeepDeletedExceptionsProbe_LDFLAGS = -Wl,-install_name,@rpath/iQKeepDeletedExceptionsProbe.dylib
iQKeepDeletedExceptionsProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
