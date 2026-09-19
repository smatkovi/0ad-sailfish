#!/bin/bash
# Stage 2, runs as the entrypoint of the already-provisioned 0ad-arm64 container
# (that container's layer holds the Debian toolchain; a fresh debian:trixie has
# no make). Relinks with libstdc++ ahead of libmozjs, then replays the reference
# game and prints the final simulation state hash.
set -e
exec > /work/stage2.log 2>&1

echo "### [1/3] game data"
cd /work/0ad-0.28.0
rm -rf binaries/data
ln -s /work/gamedata binaries/data
ls binaries/data/mods/

echo "### [2/3] relink"
rm -f binaries/system/pyrogenesis
cd build/workspaces/gcc
make -j12 LDFLAGS="-lstdc++"
cd /work/0ad-0.28.0
echo "mozjs-versioned-std-symbols=$(readelf --dyn-syms -W binaries/system/pyrogenesis | grep -c mozjs128_release || true)"
file binaries/system/pyrogenesis | cut -c1-80

echo "### [3/3] replay"
mkdir -p /work/home
cd binaries/system
HOME=/work/home ./pyrogenesis -replay=/work/commands-ref.txt 2>&1 | tail -40
echo "### DONE-STAGE2"
