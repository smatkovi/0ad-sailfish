#!/bin/bash
# Stage 5: the replay reached turn 7892 but blocked writing profile2.jsonp /
# crashlog.txt - /work is root owned while the game runs as uid 1000. Give it a
# HOME inside the container instead and keep /work read-only for the game.
exec > /work/stage5.log 2>&1

echo "### [1/2] user"
id player 2>/dev/null || useradd -m -u 1000 player
rm -rf /home/player/.local /home/player/.config /home/player/.cache
chown -R player:player /home/player
# the game also drops files next to the binary on some paths
chown -R player:player /work/0ad-0.28.0/binaries/system

echo "### [2/2] replay"
cd /work/0ad-0.28.0/binaries/system
runuser -u player -- env LD_LIBRARY_PATH=/hostlib HOME=/home/player \
    ./pyrogenesis -replay=/work/commands-ref.txt > /work/replay-arm64.log 2>&1 < /dev/null
echo "REPLAY-EXIT=$?"
grep -aE '^# Final state' /work/replay-arm64.log || { echo "NO HASH"; tail -12 /work/replay-arm64.log; }
echo "### DONE-STAGE5"
