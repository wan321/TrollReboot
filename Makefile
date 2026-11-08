TARGET = iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TrollReboot

TrollReboot_FILES = main.m AppDelegate.m RootViewController.m TRRootOps.m TRDaemon.m TRBattery.m TRMonitor.m
TrollReboot_FRAMEWORKS = UIKit Foundation
TrollReboot_CFLAGS = -fobjc-arc
TrollReboot_CODESIGN_FLAGS = -Sentitlements.plist
TrollReboot_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

after-package::
	@echo "Renaming generated .ipa to .tipa ..."
	@for ipa in ./packages/*.ipa; do \
		[ -f "$$ipa" ] || continue; \
		mv "$$ipa" "$${ipa%.ipa}.tipa"; \
	done
