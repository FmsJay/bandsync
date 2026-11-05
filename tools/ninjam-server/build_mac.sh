#!/bin/sh
# Builds lib/ninjam/ninjamsrv for Macs (Apple Silicon and Intel), on a Mac with the Command Line Tools. It's committed and
# ships through ReaPack (Macs only), so nobody else needs a compiler. Commit what it makes.
set -e
COMMIT=f4c0eff3a1d8d5f3ead470d0c7405c3ee37da24e
OUT="${1:-$(cd "$(dirname "$0")/../.." && pwd)/lib/ninjam}"
WORK="${TMPDIR:-/tmp}/ninjam-build-$$"
git clone -q https://github.com/justinfrankel/ninjam.git "$WORK"
git -C "$WORK" checkout -q "$COMMIT"
cd "$WORK/ninjam/server"
make MAC=1 CC=clang CXX=clang++ CXXFLAGS="-O2 -D_MAC -Wno-reorder -arch arm64 -arch x86_64 -mmacosx-version-min=10.13"
mkdir -p "$OUT"
cp ninjamsrv "$OUT/ninjamsrv"
lipo -info "$OUT/ninjamsrv"
cd /
rm -rf "$WORK"
