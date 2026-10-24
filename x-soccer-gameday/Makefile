TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XSoccerGameday
XSoccerGameday_FILES := XSoccerGameday.m
XSoccerGameday_CFLAGS := -fobjc-arc
XSoccerGameday_FRAMEWORKS := Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
