#!/bin/bash
# Stage 4: su wants PAM auth even from root in this image - use runuser instead.
# Full replay output goes to a log so progress (turn count) stays visible.
exec > /work/stage4.log 2>&1

echo "### [1/2] user"
id player 2>/dev/null || useradd -m -u 1000 player
mkdir -p /work/home && chown -R 1000:1000 /work/home

echo "### [2/2] replay (7892 turns, emulated)"
cd /work/0ad-0.28.0/binaries/system
runuser -u player -- env LD_LIBRARY_PATH=/hostlib HOME=/work/home \
    ./pyrogenesis -replay=/work/commands-ref.txt > /work/replay-arm64.log 2>&1
echo "REPLAY-EXIT=$?"
grep -E '^# Final state' /work/replay-arm64.log || { echo "NO HASH"; tail -15 /work/replay-arm64.log; }
echo "### DONE-STAGE4"
