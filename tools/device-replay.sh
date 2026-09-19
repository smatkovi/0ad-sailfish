#!/bin/bash
# Replay-Determinismustest auf dem Sailfish-Geraet.
#
# Erwartet das Laufzeitbundle unter $ROOT/binaries/system (pyrogenesis + die
# mitgelieferten .so) und die Spieldaten unter $ROOT/binaries/data/mods/public.
# Vergleicht den Endhash mit dem Referenzlauf von x86_64/aarch64-qemu.
#
# Wichtig: aus einem Verzeichnis starten, das dem laufenden Nutzer gehoert -
# sonst blockiert 0 A.D. am Ende beim Schreiben von profile2.jsonp.
set -e

ROOT=${ROOT:-$HOME/0ad}
REPLAY=${REPLAY:-$HOME/ps/0ad-sfos/commands-ref.txt}
REF=${REF:-e00021c80905849fc71351b076fd4381}

SYS="$ROOT/binaries/system"
export LD_LIBRARY_PATH="$SYS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$SYS"
LOG=$(mktemp -t 0ad-replay.XXXXXX)
echo "### Replay laeuft, Log: $LOG"
./pyrogenesis -replay="$REPLAY" 2>&1 | tee "$LOG"

HASH=$(grep -o '# Final state: [0-9a-f]*' "$LOG" | tail -1 | awk '{print $4}')
echo
echo "Hash Geraet:  ${HASH:-(keiner gefunden)}"
echo "Hash Referenz: $REF"
if [ "$HASH" = "$REF" ]; then
    echo "DETERMINISMUS OK"
else
    echo "ABWEICHUNG"
    exit 1
fi
