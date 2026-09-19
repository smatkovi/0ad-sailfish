#!/bin/bash
# Stage 3: 0 A.D. refuses to run as root, so replay as an unprivileged user.
# LD_LIBRARY_PATH must survive the user switch - the binfmt qemu interpreter
# needs the host libraries mounted at /hostlib for every exec.
set -e
exec > /work/stage3.log 2>&1

echo "### [1/2] prepare user"
id player 2>/dev/null || useradd -m -u 1000 player
mkdir -p /work/home
chown -R 1000:1000 /work/home
ls -la /work/0ad-0.28.0/binaries/system/pyrogenesis

echo "### [2/2] replay"
su -m player -c 'export LD_LIBRARY_PATH=/hostlib; export HOME=/work/home; cd /work/0ad-0.28.0/binaries/system && ./pyrogenesis -replay=/work/commands-ref.txt' 2>&1 | tail -25
echo "### DONE-STAGE3"
