#!/bin/sh
# CamForgeDylib 一键构建：产出 libCamForge.dylib 并签名
# 运行环境：越狱设备（apt install theos）或 Mac/Linux（theos toolchain + iOS SDK）
set -e
cd "$(dirname "$0")"

echo "==> building"
make clean >/dev/null 2>&1 || true
make

DYLIB=$(find .theos -name '*.dylib' ! -name '*-sim*' | head -1)
if [ -z "$DYLIB" ]; then
    echo "build failed: no dylib produced" >&2
    exit 1
fi

cp "$DYLIB" ./libCamForge.dylib
echo "==> built: $(pwd)/libCamForge.dylib"

# 签名：优先 ldid（tweak 标准签名），失败则 codesign ad-hoc（macOS 自带，fat 二进制无坑）。
# 注意：brew 的 ldid 是 saurik v2.1.5 旧版，对 theos 合并出的、已被 codesign 签过的
# fat 二进制会 assert 崩溃（CI 实测 2026-10-17）——所以这里必须容错，签名失败不能
# 让整个构建挂掉。CI 环境建议装 ldid-procursus（brew install ldid-procursus）。
sign_ok=0
if command -v ldid >/dev/null 2>&1; then
    if ldid -S ./libCamForge.dylib 2>/dev/null; then
        echo "==> signed with ldid"
        sign_ok=1
    else
        echo "!! ldid failed (old saurik ldid cannot re-sign fat/codesigned binaries), falling back" >&2
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
