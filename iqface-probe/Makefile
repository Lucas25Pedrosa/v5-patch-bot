ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceProbe

iQFaceProbe_FILES = Tweak.m
iQFaceProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-error=deprecated-declarations
iQFaceProbe_FRAMEWORKS = Foundation UIKit

iQFaceProbe_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
