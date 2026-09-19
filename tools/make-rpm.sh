#!/bin/bash
# Package the built 0 A.D. tree as a Sailfish aarch64 RPM.
# Run INSIDE the sfossdk52-0ad container.
#
# The 1.3 GB public.zip is deliberately NOT in the package - it gets downloaded
# on first run (or pushed manually for testing) into ~/.local/share/0ad/mods.
set -e

TARGET=${TARGET:-SailfishOS-5.2.0.15-aarch64}
TREE=${TREE:-/home/mersdk/0ad/0ad-0.28.0}
PREFIX=${PREFIX:-/home/mersdk/0ad/prefix}
WORK=${WORK:-/home/mersdk/0ad}
NAME=harbour-0ad
VERSION=0.28.0
RELEASE=${RELEASE:-1}
SB="sb2 -t $TARGET"

ROOT="$WORK/pkgroot"
rm -rf "$ROOT"
mkdir -p "$ROOT/usr/share/$NAME/binaries/system" \
         "$ROOT/usr/share/$NAME/binaries/data" \
         "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor/108x108/apps"

echo "### binaries (stripped)"
cp "$TREE/binaries/system/pyrogenesis" "$ROOT/usr/share/$NAME/binaries/system/"
cp "$TREE/binaries/system/libmozjs128-release.so" "$ROOT/usr/share/$NAME/binaries/system/"
cp "$TREE/binaries/system/libCollada.so" "$TREE"/binaries/system/libnv*.so \
   "$ROOT/usr/share/$NAME/binaries/system/"
# these four do not exist on a stock device, so they travel with us
cp -L "$PREFIX/lib/libenet.so.7" "$PREFIX/lib/libsodium.so.26" \
      "$PREFIX/lib64/libfmt.so.11" "$PREFIX/lib64/libopenal.so.1" \
      "$ROOT/usr/share/$NAME/binaries/system/"
$SB strip --strip-unneeded "$ROOT/usr/share/$NAME/binaries/system/"* 2>/dev/null || true

echo "### data (without public.zip)"
cp -a "$TREE/binaries/data/config" "$TREE/binaries/data/l10n" "$TREE/binaries/data/tools" \
      "$ROOT/usr/share/$NAME/binaries/data/" 2>/dev/null || true
mkdir -p "$ROOT/usr/share/$NAME/binaries/data/mods"
cp -a "$TREE/binaries/data/mods/mod" "$ROOT/usr/share/$NAME/binaries/data/mods/" 2>/dev/null || true

echo "### launcher"
# Two lessons from the device:
#  - sailjail refuses to sandbox a shell script ("is not elf binary"), so the
#    desktop Exec points at /bin/sh with the script as argument - same trick
#    harbour-pure-maps uses.
#  - "generic" routes through mapplauncherd's booster, which then enforces
#    sandboxing; "no-invoker" plus an explicit Sandboxing=Disabled avoids it.
# cd into a writable directory: 0 A.D. drops profile2.jsonp next to the cwd on
# exit and blocks on the error dialog if it cannot. Data is found relative to
# the executable, so cwd is free to be somewhere else.
cat > "$ROOT/usr/share/$NAME/launch.sh" <<'LAUNCH'
#!/bin/sh
ROOT=/usr/share/harbour-0ad
export LD_LIBRARY_PATH="$ROOT/binaries/system${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# the engine has its own touch layer now, so SDL must not also synthesise mouse
# events from the same fingers
export SDL_TOUCH_MOUSE_EVENTS=0
# The compositor never hands out a landscape surface, so the engine turns
# itself: it renders at 2272x1032 and blits that rotated into the portrait
# surface, rotating input coordinates back. See source/ps/DisplayRotation.h.
export PYROGENESIS_DISPLAY_ROTATION=90
export SDL_QTWAYLAND_CONTENT_ORIENTATION=landscape
RUNDIR="$HOME/.local/share/0ad"
mkdir -p "$RUNDIR"
cd "$RUNDIR"
exec "$ROOT/binaries/system/pyrogenesis" "$@"
LAUNCH
chmod 755 "$ROOT/usr/share/$NAME/launch.sh"

cat > "$ROOT/usr/bin/$NAME" <<'BIN'
#!/bin/sh
exec /usr/share/harbour-0ad/launch.sh "$@"
BIN
chmod 755 "$ROOT/usr/bin/$NAME"

cat > "$ROOT/usr/share/applications/$NAME.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=0 A.D.
Comment=Historical real-time strategy
Icon=$NAME
Exec=/bin/sh /usr/share/$NAME/launch.sh
Terminal=false
StartupNotify=false
Categories=Game;StrategyGame;
X-Nemo-Application-Type=no-invoker

[X-Sailjail]
Sandboxing=Disabled
DESK

cp "$TREE/build/resources/0ad.png" "$ROOT/usr/share/icons/hicolor/108x108/apps/$NAME.png" 2>/dev/null || true

echo "### spec"
mkdir -p "$WORK/rpmbuild"/{SPECS,RPMS,BUILD,BUILDROOT}
cat > "$WORK/rpmbuild/SPECS/$NAME.spec" <<SPEC
%define debug_package %{nil}
%define __strip /bin/true
%define _binaries_in_noarch_packages_terminate_build 0

Name:     $NAME
Version:  $VERSION
Release:  $RELEASE
Summary:  0 A.D. - historical real-time strategy
License:  GPL-2.0-or-later and CC-BY-SA-3.0
URL:      https://play0ad.com/
# Auto-generated dependencies are off (the bundled .so in a non-standard path
# would confuse them); the one real gap the device showed is libatomic, which
# our bundled libopenal needs.
AutoReqProv: no
Requires: libatomic

%description
0 A.D. (Pyrogenesis engine) built for Sailfish OS with the OpenGL ES renderer.
The game data (public.zip, ~1.3 GB) is not part of this package and belongs in
~/.local/share/0ad/mods/public/.

%install
cp -a $ROOT/* %{buildroot}/

%files
/usr/bin/$NAME
/usr/share/$NAME
/usr/share/applications/$NAME.desktop
/usr/share/icons/hicolor/108x108/apps/$NAME.png

%changelog
SPEC

echo "### rpmbuild"
$SB rpmbuild --target aarch64 \
    --define "_topdir $WORK/rpmbuild" \
    --define "_rpmdir $WORK/rpmbuild/RPMS" \
    -bb "$WORK/rpmbuild/SPECS/$NAME.spec"

find "$WORK/rpmbuild/RPMS" -name '*.rpm' -exec ls -lh {} \;
