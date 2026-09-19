#!/bin/bash
# Resume the Sailfish build in an already extracted and patched tree - skips the
# re-extract and the patch step, so a failed mozjs run does not cost another
# FCollada/nvtt/premake rebuild. Run INSIDE the sfossdk52-0ad container.
set -e

TARGET=${TARGET:-SailfishOS-5.2.0.15-aarch64}
PREFIX=${PREFIX:-/home/mersdk/0ad/prefix}
TREE=${TREE:-/home/mersdk/0ad/0ad-0.28.0}
JOBS=${JOBS:-$(nproc)}
SB="sb2 -t $TARGET"

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
export CTARGET=aarch64-unknown-linux-gnu
export HOST_CC=/home/mersdk/hostccwrap/host-cc-real
export HOST_CXX=/home/mersdk/hostccwrap/host-cxx-real
# host-cc-real runs with SBOX_DISABLE_MAPPING=1, so it sees the real /tmp while
# configure (inside sb2) writes its conftest files into the mapped one. Point
# both at a path sb2 does not map, so they agree.
export TMPDIR=/home/mersdk/tmp
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"

echo "### bundled libs (resumes, already built ones are skipped)"
cd "$TREE/libraries"
$SB ./build-source-libs.sh -j"$JOBS"

echo "### self-rotation (landscape inside the portrait surface)"
# Adds source/ps/DisplayRotation.* and wires them into VideoMode, the input
# pump and the GL backend. Idempotent, and off unless display.rotation says
# otherwise - so it changes nothing for a desktop build.
SELF=$(dirname "$0")
ROTSRC=""
for d in "$SELF" "$SELF/../src-new/ps" "$WORK/src-new/ps"; do
    [ -f "$d/DisplayRotation.cpp" ] && ROTSRC=$d && break
done
[ -n "$ROTSRC" ] || { echo "DisplayRotation.cpp not found"; exit 1; }
cp "$ROTSRC/DisplayRotation.h" "$ROTSRC/DisplayRotation.cpp" "${TREE:-$WORK/0ad-0.28.0}/source/ps/"
python3 "$SELF/apply-rotation.py" "${TREE:-$WORK/0ad-0.28.0}"

echo "### premake"
cd "$TREE/build/premake"
$SB ../../libraries/source/premake-core/bin/premake5 --file=premake5.lua \
    --outpath=../workspaces/gcc --gles \
    --without-pch --without-lobby --without-miniupnpc --without-atlas gmake

echo "### make"
cd "$TREE/build/workspaces/gcc"
$SB make -j"$JOBS" CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lstdc++"

echo "### result"
file "$TREE/binaries/system/pyrogenesis"
if readelf --dyn-syms -W "$TREE/binaries/system/pyrogenesis" | grep mozjs128_release | grep -qE '_ZNS|_ZNKS'; then
    echo "WARNING: libstdc++ symbols still bound to libmozjs"
else
    echo "link order OK"
fi
