ARCHS = arm64
TARGET = iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = XSoccerGamedayProbe
XSoccerGamedayProbe_FILES = Probe.m FeatureScan.m
XSoccerGamedayProbe_FRAMEWORKS = Foundation UIKit
XSoccerGamedayProbe_CFLAGS = -fobjc-arc -Wall -Wextra
XSoccerGamedayProbe_LDFLAGS = -Wl,-install_name,@rpath/XSoccerGamedayProbe.dylib
include $(THEOS_MAKE_PATH)/library.mk
