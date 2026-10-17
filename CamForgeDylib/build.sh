#!/bin/sh
# CamForgeDylib 一键构建：产出 libCamForge.dylib 并签名
# 运行环境：越狱设备（apt install theos）或 Mac/Linux（theos toolchain + iOS SDK）
set -e
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# FFmpeg（可选）：有 xcrun 的 macOS 环境（CI 的 macos-14 runner）自动交叉编译。
# 越狱设备上没有 xcrun，跳过 —— Makefile 检测不到 vendor/ffmpeg/lib 就自动降级，
# RTSP/RTMP/FLV 那几路标记为不可用，其余功能不受影响。
# 设 CF_SKIP_FFMPEG=1 可强制跳过（本地快速验证内存相关改动时用）。
# ---------------------------------------------------------------------------
if [ "${CF_SKIP_FFMPEG:-0}" != "1" ] && command -v xcrun >/dev/null 2>&1 \
   && [ ! -f vendor/ffmpeg/lib/libavformat.a ]; then
    echo "==> building FFmpeg (static, arm64 + arm64e)"
    ./vendor/build-ffmpeg.sh || echo "!! FFmpeg 编译失败，继续构建无 FFmpeg 版本"
fi

echo "==> building"
make clean >/dev/null 2>&1 || true
make

# ---------------------------------------------------------------------------
# 挑选真正的动态库产物。
# .theos 下匹配 *.dylib 的文件有多类，早年 find|head -1 随机抓中过 dSYM 里的
# DWARF 文件（MH_DSYM），交付物直接废掉（2026-10-17 CI 实测踩坑）：
#   .theos/obj/<cfg>/CamForge.dylib                                ← fat，合并产物，要这个
#   .theos/obj/<cfg>/<arch>/CamForge.dylib                         ← thin MH_DYLIB，单架构
#   .theos/obj/<cfg>/<arch>/CamForge.dylib.dSYM/.../CamForge.dylib ← MH_DSYM，排除
# 按 Mach-O 头筛选：fat > thin MH_DYLIB(filetype 6)，其余一律排除。
# ---------------------------------------------------------------------------
macho_kind() {
    # 输出 fat / dylib / other
    _m=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
    case "$_m" in
        cafebabe|bebafaca|cafebabf|bfbafeca) echo fat; return 0 ;;
    esac
    _ft=$(od -An -tu1 -j12 -N1 "$1" 2>/dev/null | tr -d ' \n')
    if [ "$_ft" = "6" ]; then echo dylib; else echo other; fi
}

DYLIB=""
FAT_DYLIB=""
if command -v od >/dev/null 2>&1; then
    for f in $(find .theos -name '*.dylib' ! -name '*-sim*' 2>/dev/null | LC_ALL=C sort); do
        [ -f "$f" ] || continue
        kind=$(macho_kind "$f")
        echo "    candidate: $f [$kind]"
        case "$kind" in
            fat)   FAT_DYLIB="$f" ;;
            dylib) [ -z "$DYLIB" ] && DYLIB="$f" ;;
        esac
    done
    DYLIB="${FAT_DYLIB:-$DYLIB}"
else
    # 没有 od 的环境（极少见）：退回路径启发式——排除 .dSYM 目录，取最浅路径
    echo "!! od not available, using path heuristic" >&2
    DYLIB=$(find .theos -name '*.dylib' ! -name '*-sim*' 2>/dev/null \
        | grep -v '\.dSYM/' | LC_ALL=C sort | head -1)
fi

if [ -z "$DYLIB" ]; then
    echo "build failed: no Mach-O dylib found under .theos" >&2
    exit 1
fi

cp "$DYLIB" ./libCamForge.dylib
echo "==> built: $(pwd)/libCamForge.dylib (source: $DYLIB)"

# 交付前复核 Mach-O 类型，杜绝再把 dSYM 当成品交付
kind=$(macho_kind ./libCamForge.dylib 2>/dev/null || echo other)
case "$kind" in
    fat|dylib) echo "==> verified Mach-O type: $kind" ;;
    *) echo "FATAL: libCamForge.dylib is [$kind], expected fat or dylib" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 签名。macOS 上 theos 已用 codesign 签过合并产物；设备上可能没签，这里兜底。
# 顺序 ldid → codesign ad-hoc → 只警告。签名失败不能挂掉构建。
# ---------------------------------------------------------------------------
sign_ok=0
if command -v ldid >/dev/null 2>&1; then
    if ldid -S ./libCamForge.dylib 2>/dev/null; then
        echo "==> signed with ldid"
        sign_ok=1
    else
        echo "!! ldid failed, falling back to codesign" >&2
    fi
fi
if [ "$sign_ok" -eq 0 ] && command -v codesign >/dev/null 2>&1; then
    if codesign -f -s - ./libCamForge.dylib 2>/dev/null; then
        echo "==> signed with codesign (ad-hoc)"
        sign_ok=1
    fi
fi
if [ "$sign_ok" -eq 0 ]; then
    echo "!! no signer succeeded; dylib is unsigned, most jailbreaks still load it" >&2
fi

echo "==> done: libCamForge.dylib + libCamForge.plist"
