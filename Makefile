SCHEME ?= roothide
ifneq ($(SCHEME),roothide)
$(error Pandora probe supports roothide only)
endif
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = Pandora
Pandora_FILES = Sources/Core/ProbeState.swift Sources/UI/ProbeController.swift Sources/Native/PDNative.m Sources/Native/PDHostTransformer.m Sources/Native/PDPresenterLease.m Sources/Native/PDEntry.m
Pandora_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra
Pandora_SWIFTFLAGS = -swift-version 5 -import-objc-header $(THEOS_PROJECT_DIR)/Sources/Native/PDNative.h
Pandora_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation
Pandora_LIBRARIES = substrate
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
