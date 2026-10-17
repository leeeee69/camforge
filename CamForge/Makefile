ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CamForge

CamForge_FILES = \
    Tweak.xm \
    CFManager.m \
    CFCaptureProxy.m \
    CFSyntheticSource.m \
    CFAssetSource.m \
    CFPixelConverter.m \
    CFJitterBuffer.m \
    CFLogger.m \
    CFMenu.m

CamForge_CFLAGS = -fobjc-arc
CamForge_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo Accelerate QuartzCore CoreImage Foundation
CamForge_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
