# 0 A.D. for Sailfish OS

Patches, build scripts and packaging that bring
[0 A.D.](https://play0ad.com) 0.28.0 (the Pyrogenesis engine) to Sailfish OS
phones. The port runs on OpenGL ES, in landscape, with touch controls, and is
simulation-compatible with desktop builds: a replay recorded on x86_64 ends in
the same state hash on the phone, so cross-play against PCs is possible.

Ready-made RPMs are on the
[releases page](https://github.com/smatkovi/0ad-sailfish/releases).

## Installing

The package needs `libatomic` from the Jolla repositories and `aria2` from
[SailfishOS:Chum](https://github.com/sailfishos-chum/main) (enable Chum with
Storeman or `sailfishos-chum-gui` first), both declared as dependencies:

```sh
pkcon install-local harbour-0ad-0.28.0-*.rpm
```

The RPM does **not** contain the game data. On the first start the launcher
fetches `public.zip` (1.4 GB download, 3.5 GB extracted) with aria2c over
eight connections, checks the SHA-1 published by Wildfire Games, extracts it
into `~/.local/share/0ad/mods/public/` and then starts the game. A small
progress page shows download speed and remaining time; closing it cancels,
the next start resumes the download. Wi-Fi is recommended.

If you already have `public.zip` from a desktop installation, copy it to
`~/.local/share/0ad/mods/public/public.zip` and the launcher skips the
download. To fetch it by hand:

```sh
mkdir -p ~/.local/share/0ad
cd /tmp
aria2c -x 8 https://releases.wildfiregames.com/0ad-0.28.0-unix-data.tar.xz
tar xf 0ad-0.28.0-unix-data.tar.xz --strip-components=3 \
    -C ~/.local/share/0ad/ 0ad-0.28.0/binaries/data/mods
```

The app is intentionally not sandboxed (Sailjail refuses to start shell
scripts). The launcher `sfos/launch.sh` exports `SDL_TOUCH_MOUSE_EVENTS=0`
and `PYROGENESIS_DISPLAY_ROTATION=90` and changes into `~/.local/share/0ad`
before starting the engine; `sfos/qml/harbour-0ad.qml` is the progress page,
run through `sailfish-qml`.

### Tips

- `gui.scale` in `~/.config/0ad/config/user.cfg` must stay at or below about
  1.34 on a 2272x1032 surface; larger values push dialogs such as *Load* and
  *Settings* off the screen, including their *Back* button. The shipped
  default is fine.
- Touch: tap = left click, long press = right click, drag = pan the camera,
  two fingers = zoom.
- If taps seem to do nothing or behave randomly, check for several engine
  instances fighting over the display: `pgrep` does not find `pyrogenesis`
  (empty comm field), use `readlink /proc/*/exe | grep pyrogenesis`.

## What is changed

Six patches against the 0.28.0 source tarball, in `patches/`:

| Patch | Purpose |
| --- | --- |
| 0001 | `--without-lobby` is broken in 0.28.0: `HWDetect.cpp` calls `gloox_version()` unconditionally. |
| 0002 | GLES backend: a missing fall-through in `Texture.cpp`. |
| 0003 | GLES backend: uniform buffers are only bookkeeping in the GL backend, skip the binding that ES2 cannot do. |
| 0004 | Wayland-only systems: do not assume X11 on every non-Windows, non-macOS platform. |
| 0005 | Touch input: enable the existing (Android-only) touch layer when a touch device is present, fix uninitialised synthetic click events, a missing mouse-move before clicks, and a NULL dereference in the main menu. |
| 0006 | Touch input: push synthetic clicks through the engine's priority queue so the display rotation does not transform them twice. |

`src-new/ps/DisplayRotation.{h,cpp}` plus `tools/apply-rotation.py` add the
self-rotation: the compositor only hands out a portrait surface, so the engine
renders into an offscreen framebuffer of the logical landscape size and blits
it rotated before every swap, and input coordinates are mapped back in
`in_poll_event`. It is controlled by `display.rotation` (0/90/270, default 0,
desktop builds are untouched) or the `PYROGENESIS_DISPLAY_ROTATION`
environment variable.

`data-config/default.cfg` and `keys.txt` are the configuration shipped in the
package, `sfos/` the launcher and its first-start page.

## Building

The build runs inside a Sailfish SDK (Platform SDK / scratchbox2) container
with the target `SailfishOS-5.2.0.15-aarch64` or `-armv7hl` (all scripts take
`TARGET=...`). Roughly 10 GB of disk are needed; SpiderMonkey alone produces
about 6 GB of objects.

1. Install into the target what the stock SDK target lacks:
   `boost-devel SDL2-devel libxml2-devel libcurl-devel libicu-devel
   libogg-devel libvorbis-devel nspr-devel libuuid-devel llvm
   pulseaudio-devel`.
2. `tools/sfos-deps.sh` builds enet, fmt, libsodium and openal-soft into a
   private prefix (the target does not ship them; the RPM bundles them).
3. `tools/sfos-build.sh` extracts the tarball, applies the patches and the
   rotation, and builds with `--gles --without-lobby --without-miniupnpc`.
   `tools/sfos-resume.sh` repeats only the compile step in an already
   prepared tree.
4. `tools/make-rpm.sh` packages the result as `harbour-0ad`.

Things that bit during the port and are handled by the scripts:

- `pyrogenesis` must be linked with `-lstdc++` **before** `-lmozjs128-release`,
  otherwise libstdc++ symbols resolve into libmozjs and the game crashes in
  the first simulation turn.
- SpiderMonkey needs Rust. The scripts use a rustup 1.82 toolchain with an
  i686 host and the aarch64/armv7 standard libraries, run through a wrapper
  that forces the cross linker, and configure it as a real cross build
  (`CHOST=i686-unknown-linux-gnu`, `CTARGET=aarch64-unknown-linux-gnu` or
  `armv7-unknown-linux-gnueabihf`).
- The `--gles` premake option is described as non-working upstream but only
  needs patches 0002 and 0003.

The `build-*.sh`, `stage*-arm64.sh` and `finish-arm64.sh` scripts belong to
the determinism test that was run before the Sailfish build: a desktop build
and an emulated aarch64 build (Debian under qemu-user) replay the same
recorded game (`commands-ref.txt`, 7892 turns) and must print the same final
state hash. `tools/device-replay.sh` runs the same check on the phone.

## Status

- Verified: builds, installs, starts from the icon, landscape rendering, touch
  controls in menus and in game, replay determinism against x86_64.
- Not verified: network multiplayer from the phone (the lobby is disabled;
  direct IP games should work but have not been tested).

## License

The patches, scripts and `DisplayRotation.*` are licensed under the
GNU General Public License, version 2 or later, like 0 A.D. itself
(see `LICENSE`). The game data in `public.zip` is CC BY-SA 3.0 and is not
part of this repository or the packages.
