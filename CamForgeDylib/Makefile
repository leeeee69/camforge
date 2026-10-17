ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

# library.mk 产出 libCamForge.dylib（build.sh 会统一改名/拷贝）
LIBRARY_NAME = CamForge

CamForge_FILES = \
    CFHooks.m \
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
CamForge_LDFLAGS = -lsubstrate

include $(THEOS_MAKE_PATH)/library.mk
