#!/bin/bash
# Runs on the arch build host. Waits for the emulated aarch64 build to finish,
# relinks pyrogenesis with libstdc++ ahead of libmozjs, then replays the
# reference game and reports the final state hash.
exec > /tmp/0ad-arm64/finish.log 2>&1

say() { echo "$(date -u +%H:%M:%S) $*"; }

say "WAIT: build container"
while [ "$(docker inspect -f '{{.State.Running}}' 0ad-arm64 2>/dev/null)" = "true" ]; do
    sleep 30
done
say "BUILD-EXIT=$(docker inspect -f '{{.State.ExitCode}}' 0ad-arm64 2>/dev/null)"

if ! grep -q '^### DONE' /tmp/0ad-arm64/build.log; then
    say "FAILED: build did not complete"
    tail -15 /tmp/0ad-arm64/build.log
    exit 1
fi
say "BUILD-OK"

DARGS="--rm --platform linux/arm64 -v /usr/lib:/hostlib:ro -v /usr/lib64:/lib64:ro
       -e LD_LIBRARY_PATH=/hostlib -v /tmp/0ad-arm64:/work"

# game data is arch independent - take it from the x86 tree
say "COPY: game data"
mkdir -p /tmp/0ad-arm64/0ad-0.28.0/binaries/data /tmp/0ad-arm64/home
cp -a /tmp/0ad/0ad-0.28.0/binaries/data/. /tmp/0ad-arm64/0ad-0.28.0/binaries/data/
cp /tmp/0ad/commands-ref.txt /tmp/0ad-arm64/

say "RELINK: libstdc++ before libmozjs"
docker run $DARGS -w /work debian:trixie bash -c '
    set -e
    cd /work/0ad-0.28.0
    rm -f binaries/system/pyrogenesis
    cd build/workspaces/gcc
    make -j12 LDFLAGS="-lstdc++"
    n=$(readelf --dyn-syms -W ../../../binaries/system/pyrogenesis | grep -c mozjs128_release || true)
    echo "mozjs-versioned-std-symbols=$n"
' || { say "FAILED: relink"; exit 1; }
say "RELINK-OK"

say "REPLAY: starting"
docker run $DARGS -e HOME=/work/home -w /work/0ad-0.28.0/binaries/system \
    debian:trixie ./pyrogenesis -replay=/work/commands-ref.txt \
    > /tmp/0ad-arm64/replay-arm64.log 2>&1
rc=$?
say "REPLAY-EXIT=$rc"
grep -E '^# Final state' /tmp/0ad-arm64/replay-arm64.log | tee /tmp/0ad-arm64/RESULT.txt
if [ ! -s /tmp/0ad-arm64/RESULT.txt ]; then
    say "FAILED: no hash produced"
    tail -12 /tmp/0ad-arm64/replay-arm64.log
fi
say "DONE"
