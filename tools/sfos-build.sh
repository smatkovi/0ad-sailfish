#!/bin/bash
# Build 0 A.D. 0.28.0 for a Sailfish target (aarch64 or armv7hl, TARGET=...).
# Run INSIDE the SDK container, after sfos-deps.sh.
#
# Needs roughly 10 GB free - mozjs alone is ~6 GB of objects.
set -e

TARGET=${TARGET:-SailfishOS-5.2.0.15-aarch64}
PREFIX=${PREFIX:-$HOME/0ad/prefix}
WORK=${WORK:-$HOME/0ad}
PATCHES=${PATCHES:-$WORK/patches}
JOBS=${JOBS:-$(nproc)}

SB="sb2 -t $TARGET"

# Same shape as the ESR 140 recipe in ~/share/fork01d-xulrunner-next-esr140.sh:
# rustup 1.82 with i686 host and the aarch64 std installed, handed to the build
# through PATH and RUSTC. Deliberately NO CBUILD/CHOST/CTARGET - sb2 emulates a
# native build, so telling Mozilla's configure "cross from i686 to aarch64"
# would make it hunt for a separate host compiler that does not exist here.
# Rust must go through the sb2 wrappers (tooling loader, /tmp bridge, forced
# -Clinker). A plain rustup toolchain hangs: the i686 rustc cannot resolve its
# libraries inside the sb2-mapped sysroot.
RUSTBIN="/home/mersdk/rust190root/bin"
export PATH="$RUSTBIN:$HOME/.cargo/bin:$PATH"
export RUSTC="$RUSTBIN/rustc"
# the target ships its own cargo 1.75.0-nightly in /usr/bin - mozjs would pick
# that up and trip over the version mismatch with rustc 1.82
export CARGO="$RUSTBIN/cargo"
# mozjs must be configured as a REAL cross build: sb2 makes configure believe
# host==aarch64, but rustc is an i686 binary, and mozilla's configure refuses
# ("The rust compiler host is not suitable for the configure host"). The host
# compiler for that is the container's own i486 gcc with sb2 mapping switched
# off - the same hostccwrap the gecko build here uses.
export CHOST=i686-unknown-linux-gnu
case "$TARGET" in
    *aarch64*) CTARGET=aarch64-unknown-linux-gnu ;;
    *armv7hl*) CTARGET=armv7-unknown-linux-gnueabihf ;;
    *i486*)    CTARGET=i686-unknown-linux-gnu ;;
esac
export CTARGET
export HOST_CC=/home/mersdk/hostccwrap/host-cc-real
export HOST_CXX=/home/mersdk/hostccwrap/host-cxx-real
# host-cc-real runs with SBOX_DISABLE_MAPPING=1, so it sees the real /tmp while
# configure (inside sb2) writes its conftest files into the mapped one. Point
# both at a path sb2 does not map, so they agree.
export TMPDIR=/home/mersdk/tmp
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"
rustc --version    # 1.90.0 via wrapper
cbindgen --version # must be >= 0.27

cd "$WORK"
[ -d 0ad-0.28.0 ] || {
    curl -sL https://releases.wildfiregames.com/0ad-0.28.0-unix-build.tar.xz -o src.tar.xz
    tar xf src.tar.xz && rm src.tar.xz
}
cd 0ad-0.28.0

echo "### patches"
# no "|| true" here on purpose: a silently unapplied 0003 gives exactly the
# GLES crash this whole exercise was about
# idempotent, so the script can be re-run on a prepared tree after a failure
for p in "$PATCHES"/000*.patch; do
    if out=$(patch -p0 -N -r - --dry-run < "$p" 2>&1); then
        patch -p0 -N -r - < "$p"
    elif printf '%s' "$out" | grep -q "previously applied"; then
        echo "already applied: $(basename "$p")"
    else
        printf '%s\n' "$out"; echo "patch failed: $p"; exit 1
    fi
done

echo "### SpiderMonkey 128"
# release only (patch 0007): the debug variant is never linked here
export SKIP_JS_DEBUG=1
cd libraries
$SB ./build-source-libs.sh -j"$JOBS"
cd ..

echo "### self-rotation (landscape inside the portrait surface)"
# Adds source/ps/DisplayRotation.* and wires them into VideoMode, the input
# pump and the GL backend. Idempotent, and off unless display.rotation says
# otherwise - so it changes nothing for a desktop build.
SELF=$(cd "$(dirname "$0")" && pwd)   # absolute: the tree is our cwd by now
ROTSRC=""
for d in "$SELF" "$SELF/../src-new/ps" "$WORK/src-new/ps"; do
    [ -f "$d/DisplayRotation.cpp" ] && ROTSRC=$d && break
done
[ -n "$ROTSRC" ] || { echo "DisplayRotation.cpp not found"; exit 1; }
cp "$ROTSRC/DisplayRotation.h" "$ROTSRC/DisplayRotation.cpp" "${TREE:-$WORK/0ad-0.28.0}/source/ps/"
python3 "$SELF/apply-rotation.py" "${TREE:-$WORK/0ad-0.28.0}"

echo "### premake (GLES, no lobby/upnp/atlas - none of those libs exist on the target)"
cd build/premake
$SB ../../libraries/source/premake-core/bin/premake5 --file=premake5.lua \
    --outpath=../workspaces/gcc --gles \
    --without-pch --without-lobby --without-miniupnpc --without-atlas gmake

echo "### make"
cd ../workspaces/gcc
# -lstdc++ MUST come before -lmozjs128-release, otherwise the linker resolves
# libstdc++ symbols out of libmozjs and the game segfaults on the first turn
$SB make -j"$JOBS" CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lstdc++"

echo "### result"
file ../../../binaries/system/pyrogenesis
readelf --dyn-syms -W ../../../binaries/system/pyrogenesis | grep mozjs128_release | grep -cE '_ZNS|_ZNKS' \
    && echo "WARNING: libstdc++ symbols still bound to libmozjs" || echo "link order OK"
