ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceDiagnostic

iQFaceDiagnostic_FILES = Diagnostic.m
iQFaceDiagnostic_FRAMEWORKS = Foundation UIKit
iQFaceDiagnostic_CFLAGS = -fobjc-arc -Wall -Wextra
iQFaceDiagnostic_LDFLAGS = -Wl,-install_name,@rpath/iQFaceDiagnostic.dylib
iQFaceDiagnostic_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
