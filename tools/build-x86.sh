#!/bin/bash
set -e
PREFIX=/tmp/0ad/prefix
export CARGO_HOME=/tmp/0ad/cargo
export PATH=$PREFIX/bin:$PATH
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
mkdir -p $PREFIX

echo "### [1/5] cbindgen"
command -v cbindgen >/dev/null || cargo install --quiet --root $PREFIX cbindgen
cbindgen --version

echo "### [2/5] enet"
if ! pkg-config --exists libenet; then
  cd /tmp/0ad
  curl -sL http://enet.bespin.org/download/enet-1.3.18.tar.gz -o enet.tar.gz
  tar xf enet.tar.gz && cd enet-1.3.18
  ./configure --prefix=$PREFIX --quiet
  make -j16 >/dev/null && make install >/dev/null
fi
pkg-config --modversion libenet

echo "### [3/5] bundled libs (spidermonkey 128, nvtt, fcollada, premake)"
cd /tmp/0ad/0ad-0.28.0/libraries
./build-source-libs.sh -j16

echo "### [4/5] premake"
cd ../build/workspaces
./update-workspaces.sh -j16 --without-pch --without-lobby --without-miniupnpc --without-atlas

echo "### [5/5] make"
cd gcc
make -j16
echo "### DONE"
