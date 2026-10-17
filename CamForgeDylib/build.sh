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

# 签名：设备上用 ldid，Mac 上用 codesign 临时签
if command -v ldid >/dev/null 2>&1; then
    ldid -S ./libCamForge.dylib
    echo "==> signed with ldid"
elif command -v codesign >/dev/null 2>&1; then
    codesign -f -s - ./libCamForge.dylib
    echo "==> signed with codesign (ad-hoc)"
else
    echo "!! no signer found (ldid/codesign), dylib may fail to load" >&2
fi

echo "==> done: libCamForge.dylib + libCamForge.plist"
