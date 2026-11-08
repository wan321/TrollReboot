TARGET = iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BatteryGuard
BatteryGuard_FILES = BGMain.m ../TRBattery.m ../TRMonitor.m ../TRRootOps.m
BatteryGuard_CFLAGS = -fobjc-arc -I.. -Wno-unused-but-set-variable
BatteryGuard_FRAMEWORKS = UIKit Foundation IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
