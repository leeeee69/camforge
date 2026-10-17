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
    CFAlbumSource.m \
    CFExternalSource.m \
    CFDirectSource.m \
    CFMovieSource.m \
    CFPixelConverter.m \
    CFJitterBuffer.m \
    CFLogger.m \
    CFMenu.m

CamForge_CFLAGS = -fobjc-arc
CamForge_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo Accelerate QuartzCore CoreImage Foundation Photos PhotosUI
CamForge_LDFLAGS = -lsubstrate

# ── FFmpeg（可选）─────────────────────────────────────────────────────────────
# CI 先跑 vendor/build-ffmpeg.sh 产出 vendor/ffmpeg/lib/*.a（arm64+arm64e fat）。
# 没有这些库时（比如在越狱设备上直接 ./build.sh）自动降级：不定义 CF_HAVE_FFMPEG，
# CFMovieSource 退化为「不可用」，其余功能照常。
FFMPEG_LIBAVFORMAT := $(wildcard vendor/ffmpeg/lib/libavformat.a)
ifneq ($(FFMPEG_LIBAVFORMAT),)
CamForge_CFLAGS += -Ivendor/ffmpeg/include -DCF_HAVE_FFMPEG=1
CamForge_LDFLAGS += -Lvendor/ffmpeg/lib -lavformat -lavcodec -lswscale -lswresample -lavutil -lz -lbz2 -liconv
CamForge_FRAMEWORKS += VideoToolbox
endif

include $(THEOS_MAKE_PATH)/library.mk
