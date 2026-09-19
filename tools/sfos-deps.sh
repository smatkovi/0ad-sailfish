#!/bin/bash
# Build the four libraries 0 A.D. needs that the Sailfish aarch64 target does
# not ship. Everything lands in a prefix, so the shared target sysroot stays
# untouched - other projects use that target too.
#
# Run INSIDE the sfossdk52 container:  bash sfos-deps.sh
#
# UNTESTED - written while the build host had no free disk space.
set -e

TARGET=${TARGET:-SailfishOS-5.2.0.15-aarch64}
PREFIX=${PREFIX:-$HOME/0ad/prefix}
SRC=${SRC:-$HOME/0ad/src}
JOBS=${JOBS:-$(nproc)}

SB="sb2 -t $TARGET"
mkdir -p "$PREFIX" "$SRC"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"

fetch() { # url, dirname
    cd "$SRC"
    [ -d "$2" ] && return 0
    curl -sL "$1" -o "$2.tar.gz"
    mkdir -p "$2" && tar xf "$2.tar.gz" -C "$2" --strip-components=1
}

# No --host: under sb2 this is an emulated NATIVE build, not a cross build.
# The toolchain reports itself as aarch64-meego-linux-gnu (gcc -dumpmachine),
# so config.guess gets it right on its own; forcing --host would switch
# autoconf into cross mode and disable its run-tests for no reason.
echo "### enet (mandatory - the whole netcode)"
fetch http://enet.bespin.org/download/enet-1.3.18.tar.gz enet
cd "$SRC/enet"
$SB ./configure --prefix="$PREFIX"
$SB make -j"$JOBS"
$SB make install

echo "### libsodium (mandatory)"
fetch https://download.libsodium.org/libsodium/releases/libsodium-1.0.20.tar.gz libsodium
cd "$SRC/libsodium"
$SB ./configure --prefix="$PREFIX"
$SB make -j"$JOBS"
$SB make install

echo "### fmt (mandatory)"
fetch https://github.com/fmtlib/fmt/archive/refs/tags/11.0.2.tar.gz fmt
cd "$SRC/fmt"
$SB cmake -B build -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=ON -DFMT_TEST=OFF
$SB cmake --build build -j"$JOBS"
$SB cmake --install build

echo "### openal-soft (only needed without --without-audio)"
# ATTENTION: this is the ONE change that touches the shared target sysroot -
# everything else stays in the prefix. Other projects use this target too, so
# install it deliberately, not by accident:
#   sb2 -t $TARGET -m sdk-install -R zypper in pulseaudio-devel
# Skip openal entirely and build 0 A.D. with --without-audio if that is not wanted.
# CMake in the target is 3.31.8, so -B and --install are fine.
fetch https://github.com/kcat/openal-soft/archive/refs/tags/1.23.1.tar.gz openal-soft
cd "$SRC/openal-soft"
$SB cmake -B build -DCMAKE_INSTALL_PREFIX="$PREFIX" -DALSOFT_EXAMPLES=OFF -DALSOFT_UTILS=OFF \
    -DALSOFT_BACKEND_PULSEAUDIO=ON -DALSOFT_BACKEND_ALSA=OFF
$SB cmake --build build -j"$JOBS"
$SB cmake --install build

echo "### done - pkg-config sees:"
for p in libenet libsodium fmt openal; do
    printf '%-10s ' "$p"; pkg-config --modversion "$p" 2>/dev/null || echo MISSING
done
