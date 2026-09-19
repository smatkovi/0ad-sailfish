#!/bin/bash
set -e
exec > /work/build.log 2>&1
export DEBIAN_FRONTEND=noninteractive
echo "### [1/4] apt"
apt-get -qq update
apt-get -qq install --no-install-recommends -y build-essential cmake python3 python3-venv \
  rustc cargo cbindgen libclang-dev llvm zip pkg-config file which patch m4 perl \
  libsdl2-dev libboost-dev libboost-filesystem-dev libboost-system-dev libicu-dev libenet-dev \
  libxml2-dev libcurl4-openssl-dev libfmt-dev libfreetype-dev libpng-dev libogg-dev \
  libvorbis-dev libopenal-dev libsodium-dev libnspr4-dev zlib1g-dev > /dev/null
apt-get clean
which llvm-objdump; gcc --version | head -1; rustc --version
echo "### [2/4] unpack + patch"
cd /work && rm -rf 0ad-0.28.0 && tar xf 0ad-0.28.0-unix-build.tar.xz
cd /work/0ad-0.28.0
sed -i "s/\[ \"\${OS}\" != \"FreeBSD\" \]/false/" libraries/source/spidermonkey/build.sh
echo "freebsd-guards-disabled: $(grep -c "if false; then" libraries/source/spidermonkey/build.sh)"
patch -p0 < /work/0001-hwdetect-guard-gloox.patch
echo "### [3/4] bundled libs (mozjs 128, release only)"
cd /work/0ad-0.28.0/libraries && ./build-source-libs.sh -j12
echo "### [4/4] premake + make"
cd ../build/workspaces && ./update-workspaces.sh --without-pch --without-lobby --without-miniupnpc --without-atlas
cd gcc && make -j12
echo "### DONE"
file /work/0ad-0.28.0/binaries/system/pyrogenesis
