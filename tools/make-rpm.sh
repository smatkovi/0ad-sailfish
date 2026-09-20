#!/bin/bash
# Package the built 0 A.D. tree as a Sailfish RPM (arch follows TARGET).
# Run INSIDE the SDK container.
#
# The 3.5 GB public.zip is deliberately NOT in the package - launch.sh downloads
# it on the first start (see sfos/launch.sh) into ~/.local/share/0ad/mods.
set -e

TARGET=${TARGET:-SailfishOS-5.2.0.15-aarch64}
TREE=${TREE:-/home/mersdk/0ad/0ad-0.28.0}
WORK=${WORK:-/home/mersdk/0ad}
# Derived from WORK, never a path of its own: passing WORK for the armv7hl
# tree while PREFIX still pointed at the aarch64 one put an aarch64 libopenal
# into an armv7hl package, and strip's "file format not recognized" was
# swallowed by a || true.
PREFIX=${PREFIX:-$WORK/prefix}
NAME=harbour-0ad
VERSION=0.28.0
RELEASE=${RELEASE:-1}
SB="sb2 -t $TARGET"
FILES=${FILES:-$(dirname "$(readlink -f "$0")")/../sfos}

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
# (cmake installs into lib64 on aarch64 and into lib on armv7hl)
for l in libenet.so.7 libsodium.so.26 libfmt.so.11 libopenal.so.1; do
    f=$(ls "$PREFIX/lib64/$l" "$PREFIX/lib/$l" 2>/dev/null | head -n 1)
    [ -n "$f" ] || { echo "missing $l in $PREFIX"; exit 1; }
    cp -L "$f" "$ROOT/usr/share/$NAME/binaries/system/"
done
# Strip each file by name and complain when one will not strip: silencing the
# whole glob once hid an aarch64 library sitting in an armv7hl package, where
# the only symptom was "file format not recognized" going to /dev/null.
for f in "$ROOT/usr/share/$NAME/binaries/system/"*; do
    [ -f "$f" ] || continue
    $SB strip --strip-unneeded "$f" 2>/dev/null ||
        echo "WARNING: cannot strip $(basename "$f") - wrong architecture?" >&2
done

echo "### data (without public.zip)"
cp -a "$TREE/binaries/data/config" "$TREE/binaries/data/l10n" "$TREE/binaries/data/tools" \
      "$ROOT/usr/share/$NAME/binaries/data/" 2>/dev/null || true

# The repository's own default.cfg wins: it carries the touch settings and
# turns off mouse edge scrolling, which has nothing to push against on a
# phone and otherwise runs for ever after a tap near the edge. The directory
# is created here rather than assumed - the armv7hl tree has no
# binaries/data/config of its own, and the copy above is allowed to fail.
if [ -f "$FILES/../data-config/default.cfg" ]; then
    mkdir -p "$ROOT/usr/share/$NAME/binaries/data/config"
    cp "$FILES/../data-config/default.cfg" "$FILES/../data-config/keys.txt" \
       "$ROOT/usr/share/$NAME/binaries/data/config/"
else
    echo "WARNING: data-config/default.cfg not found, shipping upstream config" >&2
fi
mkdir -p "$ROOT/usr/share/$NAME/binaries/data/mods"
cp -a "$TREE/binaries/data/mods/mod" "$ROOT/usr/share/$NAME/binaries/data/mods/" 2>/dev/null || true

echo "### launcher"
# Two lessons from the device:
#  - sailjail refuses to sandbox a shell script ("is not elf binary"), so the
#    desktop Exec points at /bin/sh with the script as argument - same trick
#    harbour-pure-maps uses.
#  - "generic" routes through mapplauncherd's booster, which then enforces
#    sandboxing; "no-invoker" plus an explicit Sandboxing=Disabled avoids it.
# launch.sh and the first-start progress page live next to this script in
# sfos/ (repository: sfos/launch.sh, sfos/qml/harbour-0ad.qml).
cp "$FILES/launch.sh" "$ROOT/usr/share/$NAME/launch.sh"
chmod 755 "$ROOT/usr/share/$NAME/launch.sh"
mkdir -p "$ROOT/usr/share/$NAME/qml"
cp "$FILES/qml/harbour-0ad.qml" "$ROOT/usr/share/$NAME/qml/"

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
# first-start download of the game data (aria2 comes from SailfishOS:Chum)
Requires: aria2
Requires: libsailfishapp-launcher

%description
0 A.D. (Pyrogenesis engine) built for Sailfish OS with the OpenGL ES renderer.
The game data (public.zip, 3.5 GB) is not part of this package. The launcher
downloads it on the first start with aria2c into ~/.local/share/0ad/mods/public/.

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
case "$TARGET" in *armv7hl*) RPMARCH=armv7hl ;; *i486*) RPMARCH=i486 ;; *) RPMARCH=aarch64 ;; esac
$SB rpmbuild --target "$RPMARCH" \
    --define "_topdir $WORK/rpmbuild" \
    --define "_rpmdir $WORK/rpmbuild/RPMS" \
    -bb "$WORK/rpmbuild/SPECS/$NAME.spec"

find "$WORK/rpmbuild/RPMS" -name '*.rpm' -exec ls -lh {} \;
