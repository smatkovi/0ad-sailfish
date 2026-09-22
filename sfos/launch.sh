#!/bin/sh
# Launcher for 0 A.D. on Sailfish OS. Started by the launcher icon through
# /bin/sh (sailjail refuses to sandbox a shell script directly).
#
# First start: the game data (public.zip 3.5 GB, mod.zip 89 MB) is not part of
# the RPM. It is fetched with aria2c (eight connections, resumable), verified against the
# SHA-1 published by Wildfire Games, extracted into ~/.local/share/0ad/mods and
# the archive is removed again. A small Silica page (qml/harbour-0ad.qml, run
# through sailfish-qml) shows the progress; closing it cancels, the next start
# resumes where it stopped.
ROOT=/usr/share/harbour-0ad
export LD_LIBRARY_PATH="$ROOT/binaries/system${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# the engine has its own touch layer, so SDL must not also synthesise mouse
# events from the same fingers
export SDL_TOUCH_MOUSE_EVENTS=0
# The compositor never hands out a landscape surface, so the engine turns
# itself: it renders at 2272x1032 and blits that rotated into the portrait
# surface, rotating input coordinates back. See source/ps/DisplayRotation.h.
export PYROGENESIS_DISPLAY_ROTATION=90
export SDL_QTWAYLAND_CONTENT_ORIENTATION=landscape

DATA="$HOME/.local/share/0ad"
PUBLIC="$DATA/mods/public/public.zip"
# the base mod is not optional: it holds the .rng grammars, the base shaders and
# globalscripts/l10n.js. Without it the engine starts and then dies in the main
# menu with "translateWithContext is not defined". Releases 9-12 never unpacked
# it, so an install made by those needs it fetched afterwards.
MOD="$DATA/mods/mod/mod.zip"
DL="$DATA/download"
ARCHIVE_NAME=0ad-0.28.0-unix-data.tar.xz
ARCHIVE="$DL/$ARCHIVE_NAME"
URL="https://releases.wildfiregames.com/$ARCHIVE_NAME"
ARCHIVE_BYTES=1415012652
ARCHIVE_SHA1=9f3220425341978c8bc01ea23349f0ee314cdc5b
PUBLIC_BYTES=3508827314
MOD_BYTES=93421350
# read by qml/harbour-0ad.qml once a second: "phase|percent|message"
STATUS="$DATA/setup-status"
LOG="$DATA/setup.log"

# cd into a writable directory: 0 A.D. drops profile2.jsonp next to the cwd on
# exit and blocks on the error dialog if it cannot. Data is found relative to
# the executable, so cwd is free to be somewhere else.
mkdir -p "$DATA"
cd "$DATA" || exit 1

start_game() {
    rm -f "$STATUS"
    # Keep stdout and stderr: the touch layer traces gestures with
    # debug_printf, which never reaches mainlog.html, and started from the
    # icon there is nowhere for it to go otherwise. Truncated every start, so
    # it cannot grow without bound.
    exec "$ROOT/binaries/system/pyrogenesis" "$@" > "$DATA/run.log" 2>&1
}

size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }

# any archive of plausible size counts, also one the user copied by hand
public_ready() { [ "$(size_of "$PUBLIC")" -ge 1000000000 ]; }
mod_ready() { [ "$(size_of "$MOD")" -ge 50000000 ]; }
data_ready() { public_ready && mod_ready; }

data_ready && start_game "$@"

# ---- first start: fetch the game data ------------------------------------

UI=
status() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"; }
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
ui_alive() { [ -n "$UI" ] && kill -0 "$UI" 2>/dev/null; }
fail() {
    log "ERROR: $1"
    status error 0 "$1"
    # leave the page open so the message can be read; it closes on swipe
    ui_alive && wait "$UI"
    exit 1
}
cancelled() {
    log "cancelled by closing the window"
    [ -n "$1" ] && kill "$1" 2>/dev/null
    rm -f "$STATUS"
    exit 1
}

mkdir -p "$DL"
: > "$LOG"
log "game data missing, starting setup"
status prepare -1 "Preparing…"
if command -v sailfish-qml >/dev/null 2>&1; then
    sailfish-qml harbour-0ad >/dev/null 2>&1 &
    UI=$!
fi

command -v aria2c >/dev/null 2>&1 || fail "aria2c is missing. Install the aria2 package (SailfishOS:Chum) and start again."

# fetch only what is missing: an install from release 9-12 has a good public.zip
# and lacks nothing but mod.zip, which saves unpacking 3.5 GB again
MEMBERS=
unpack_bytes=0
public_ready || { MEMBERS="$MEMBERS 0ad-0.28.0/binaries/data/mods/public"; unpack_bytes=$(( unpack_bytes + PUBLIC_BYTES )); }
mod_ready || { MEMBERS="$MEMBERS 0ad-0.28.0/binaries/data/mods/mod"; unpack_bytes=$(( unpack_bytes + MOD_BYTES )); }

avail_kb=$(df -Pk "$DATA" | awk 'NR==2 {print $4}')
need_kb=$(( (ARCHIVE_BYTES + unpack_bytes) / 1024 + 262144 ))
[ "$(size_of "$ARCHIVE")" -eq "$ARCHIVE_BYTES" ] && need_kb=$(( unpack_bytes / 1024 + 262144 ))
[ "${avail_kb:-0}" -ge "$need_kb" ] || fail "Not enough free space: about $(( need_kb / 1048576 + 1 )) GB are needed in $DATA."

# the base mod alone still costs the whole archive, so say why
if public_ready; then
    dmsg="Downloading the base mod (the whole 1.4 GB archive holds it)…"
else
    dmsg="Downloading game data (1.4 GB)…"
fi
if [ "$(size_of "$ARCHIVE")" -ne "$ARCHIVE_BYTES" ] || [ -f "$ARCHIVE.aria2" ]; then
    log "downloading $URL"
    status download 0 "$dmsg"
    aria2c -x 8 -s 8 -k 4M -c --summary-interval=1 --console-log-level=warn \
        --auto-file-renaming=false --allow-piece-length-change=true \
        --always-resume=true --max-tries=5 --retry-wait=3 \
        -d "$DL" -o "$ARCHIVE_NAME" "$URL" > "$DL/aria2.log" 2>&1 &
    DLP=$!
    while kill -0 "$DLP" 2>/dev/null; do
        # aria2 prints e.g. [#4926fa 1.0GiB/1.3GiB(75%) CN:8 DL:2.4MiB ETA:4m35s]
        line=$(tr '\r' '\n' < "$DL/aria2.log" | grep '^\[#' | tail -n 1)
        pct=$(printf '%s' "$line" | sed -n 's/.*(\([0-9]*\)%).*/\1/p')
        speed=$(printf '%s' "$line" | sed -n 's/.*DL:\([0-9.]*[KMG]\{0,1\}i\{0,1\}B\).*/\1/p')
        eta=$(printf '%s' "$line" | sed -n 's/.*ETA:\([0-9dhms]*\).*/\1/p')
        msg="$dmsg"
        [ -n "$speed" ] && msg="$msg $speed/s"
        [ -n "$eta" ] && msg="$msg, ETA $eta"
        status download "${pct:-0}" "$msg"
        [ -n "$UI" ] && ! ui_alive && cancelled "$DLP"
        sleep 1
    done
    wait "$DLP"
    rc=$?
    log "aria2c exit $rc"
    [ "$rc" -eq 0 ] || fail "Download failed (aria2c exit code $rc, see $LOG). Start again to resume."
fi

status verify -1 "Checking the download…"
sum=$(sha1sum "$ARCHIVE" | cut -d ' ' -f 1)
log "sha1 $sum"
if [ "$sum" != "$ARCHIVE_SHA1" ]; then
    rm -f "$ARCHIVE" "$ARCHIVE.aria2"
    fail "The download is damaged and was removed. Start again to download it once more."
fi
[ -n "$UI" ] && ! ui_alive && cancelled

# the whole archive has to come down even for the 89 MB mod.zip alone: xz is
# not seekable and Wildfire Games publishes no separate archive for it
PART="$DATA/mods/.part"
if public_ready; then
    xmsg="Extracting the base mod (89 MB)…"
    watch="$PART/mod/mod.zip"; watch_bytes=$MOD_BYTES
else
    xmsg="Extracting game data (3.5 GB)…"
    watch="$PART/public/public.zip"; watch_bytes=$PUBLIC_BYTES
fi
status extract 0 "$xmsg"
rm -rf "$PART"
mkdir -p "$PART"
# strip-components=4 keeps the mod directories themselves, so public/public.zip
# and mod/mod.zip land side by side (busybox tar 1.36 takes several members)
tar xf "$ARCHIVE" -C "$PART" --strip-components=4 $MEMBERS > "$DL/tar.log" 2>&1 &
TP=$!
while kill -0 "$TP" 2>/dev/null; do
    done_b=$(size_of "$watch")
    pct=$(( done_b / (watch_bytes / 100 + 1) ))
    [ "$pct" -gt 99 ] && pct=99
    status extract "$pct" "$xmsg"
    [ -n "$UI" ] && ! ui_alive && { kill "$TP" 2>/dev/null; rm -rf "$PART"; cancelled; }
    sleep 1
done
wait "$TP"
rc=$?
log "tar exit $rc"
if [ "$rc" -ne 0 ] || [ "$(size_of "$watch")" -lt "$watch_bytes" ]; then
    rm -rf "$PART"
    fail "Extracting failed (tar exit code $rc, see $LOG)."
fi
for m in public mod; do
    [ -d "$PART/$m" ] || continue
    rm -rf "$DATA/mods/$m"
    mv "$PART/$m" "$DATA/mods/$m"
done
rm -rf "$PART"
rm -rf "$DL"
log "game data ready"
status done 100 "Game data ready, starting…"
sleep 1
[ -n "$UI" ] && kill "$UI" 2>/dev/null
start_game "$@"
