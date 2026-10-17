#!/bin/sh
# 交叉编译 FFmpeg 静态库（arm64 / arm64e），供 libCamForge 链接
#
# 产出：
#   vendor/ffmpeg/lib/*.a        fat 静态库（两架构，lipo 合并）
#   vendor/ffmpeg/include/*.h    头文件
#   vendor/ffmpeg/ARCHS          实际构建成功的架构（both / arm64）
#
# 只开需要的组件：rtsp/rtmp/http-flv/hls + h264/hevc/aac 解码。
# 不开 gpl、不开外部库（openssl/libx264…），保持体积和合规成本最低。
#
# 用法：./build-ffmpeg.sh           （幂等，已产出则跳过）
#       FORCE=1 ./build-ffmpeg.sh   （强制重建）
set -e

FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.2}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/ffmpeg"
SRC="$ROOT/.src"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
MIN_IOS="15.0"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

if [ -f "$OUT/lib/libavformat.a" ] && [ "${FORCE:-0}" != "1" ]; then
    log "FFmpeg 已构建，跳过（FORCE=1 可强制重建）"
    cat "$OUT/ARCHS" 2>/dev/null || true
    exit 0
fi

mkdir -p "$SRC" "$OUT/lib" "$OUT/include"

# ── 源码 ─────────────────────────────────────────────────────────────────────
TARBALL="$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
    log "下载 ffmpeg-$FFMPEG_VERSION"
    curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" \
        "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
fi
if [ ! -d "$SRC/ffmpeg-$FFMPEG_VERSION" ]; then
    log "解压源码"
    tar -xf "$TARBALL" -C "$SRC"
fi

# ── 单架构构建 ───────────────────────────────────────────────────────────────
build_arch() {
    ARCH="$1"
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    WORK="$SRC/build-$ARCH"
    PREFIX="$OUT/$ARCH"
    rm -rf "$WORK"
    mkdir -p "$WORK"

    CC="clang -arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
    log "configure ($ARCH)  sdk=$SDK"

    cd "$WORK"
    "$SRC/ffmpeg-$FFMPEG_VERSION/configure" \
        --prefix="$PREFIX" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch=arm64 \
        --cpu=armv8 \
        --cc="$CC" \
        --cxx="$CC++" \
        --as="$CC" \
        --sysroot="$SDK" \
        --enable-static --disable-shared --enable-pic \
        --disable-programs --disable-doc --disable-avdevice \
        --disable-postproc --disable-avfilter --disable-debug \
        --disable-everything \
        --enable-network \
        --enable-protocol=file,http,tcp,udp,rtp,rtsp,rtmp,crypto,data,hls \
        --enable-demuxer=rtsp,sdp,flv,live_flv,mpegts,h264,hevc,aac,mov,mp4,m4v,matroska,hls \
        --enable-decoder=h264,hevc,aac,mp3 \
        --enable-parser=h264,hevc,aac,mpegvideo \
        --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
        --enable-swscale --enable-swresample \
        --extra-cflags="-arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS -fPIC" \
        --extra-ldflags="-arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS"

    log "make ($ARCH) -j$JOBS"
    make -j"$JOBS" >/dev/null
    make install >/dev/null
    log "done ($ARCH)"
}

# arm64 必须成功；arm64e 尽力而为（失败就只出 arm64 薄库）
build_arch arm64
ARCHS_RESULT="arm64"

if build_arch arm64e; then
    ARCHS_RESULT="both"
else
    log "arm64e 构建失败，降级为仅 arm64"
fi

# ── 合并 fat 库 + 头文件 ─────────────────────────────────────────────────────
log "合并静态库"
for lib in avformat avcodec avutil swscale swresample; do
    A="$OUT/arm64/lib/lib$lib.a"
    B="$OUT/arm64e/lib/lib$lib.a"
    if [ ! -f "$A" ]; then
        log "缺少 $A，构建失败"
        exit 1
    fi
    if [ -f "$B" ]; then
        lipo -create "$A" "$B" -output "$OUT/lib/lib$lib.a"
    else
        cp "$A" "$OUT/lib/lib$lib.a"
    fi
done

cp -R "$OUT/arm64/include/"* "$OUT/include/" 2>/dev/null || true
echo "$ARCHS_RESULT" > "$OUT/ARCHS"

log "FFmpeg 构建完成：$(ls -1 "$OUT/lib" | tr '\n' ' ')"
log "架构：$ARCHS_RESULT"
du -sh "$OUT" 2>/dev/null || true
