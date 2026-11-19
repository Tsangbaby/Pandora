ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PandoraPrefs
PandoraPrefs_FILES = ../Sources/Prefs/RootListController.swift
PandoraPrefs_INSTALL_PATH = /Library/PreferenceBundles
PandoraPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
PandoraPrefs_SWIFTFLAGS = -swift-version 5 -import-objc-header ../Sources/Prefs/PandoraPrefs-Bridging-Header.h
PandoraPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
PandoraPrefs_RESOURCE_DIRS = Resources
include $(THEOS_MAKE_PATH)/bundle.mk
