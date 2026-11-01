#!/bin/sh
# Builds lib/mac/bandsync-hide.dylib and lib/mac/bandsync-launch, on a Mac with the Command Line Tools. They're committed
# and ship through ReaPack (Macs only), so bandmates need no compiler. Run from anywhere; commit what it makes.
set -e
cd "$(dirname "$0")/../.."
OUT="${1:-lib/mac}"
mkdir -p "$OUT"
ARCH="-arch arm64 -arch x86_64 -mmacosx-version-min=10.13"
clang -dynamiclib -framework Cocoa $ARCH tools/mac/hide.m -o "$OUT/bandsync-hide.dylib"
clang $ARCH tools/mac/launch.c -o "$OUT/bandsync-launch"
lipo -info "$OUT/bandsync-hide.dylib" "$OUT/bandsync-launch"
