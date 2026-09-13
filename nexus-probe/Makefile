ARCHS = arm64
TARGET = iphone:clang:latest:14.0
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = NexusProbe
NexusProbe_FILES = Tweak.m
NexusProbe_FRAMEWORKS = Foundation UIKit
NexusProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-error=unused-function
NexusProbe_LDFLAGS = -Wl,-install_name,@rpath/NexusProbe.dylib
include $(THEOS_MAKE_PATH)/library.mk
