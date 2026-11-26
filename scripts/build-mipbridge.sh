#!/bin/zsh
# Builds native/mipbridge into vendor/mip/lib/libniivo_mipbridge.dylib against the MIP SDK in vendor/mip/sdk.
# Kept out of SwiftPM on purpose: no existing product links the MIP SDK, so `swift build` is unaffected whether or
# not vendor/mip exists. ProtectedContent loads the dylib at runtime (dlopen). See docs/MIP.md.
#
# usage: scripts/build-mipbridge.sh            (expects vendor/mip/sdk extracted from the official zip)
# Command Line Tools clang++ is enough; set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer per command if
# you want Xcode's toolchain instead (never `xcode-select -s` for this).
set -euo pipefail
root=${0:A:h:h}
sdk=$root/vendor/mip/sdk
arch=${MIP_ARCH:-arm64}
bins=$sdk/bins/release/$arch
out=$root/vendor/mip/lib
[[ -f $sdk/include/mip/file/file_engine.h && -f $bins/libmip_file_sdk.dylib ]] || {
  echo "MIP SDK not found under $sdk (see docs/MIP.md: download + extract)" >&2; exit 1; }
mkdir -p $out
clang++ -std=c++17 -O2 -fvisibility=hidden -fPIC -dynamiclib -arch $arch -mmacosx-version-min=15.0 \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -isystem $sdk/include -I$root/Sources/MIPBridgeABI/include \
  -Wl,-exported_symbols_list,$root/native/mipbridge/exports.txt \
  $root/native/mipbridge/niivo_mipbridge.cpp \
  -L$bins -lmip_file_sdk -lmip_protection_sdk -lmip_upe_sdk -lmip_core \
  -install_name @rpath/libniivo_mipbridge.dylib \
  -Wl,-rpath,@loader_path/../sdk/bins/release/$arch \
  -o $out/libniivo_mipbridge.dylib
codesign --force --sign - $out/libniivo_mipbridge.dylib 2>/dev/null || true
echo "built $out/libniivo_mipbridge.dylib (SDK $(cat $sdk/version.txt 2>/dev/null || echo '?'), $arch)"
