# Build wlroots with Xwayland on the Host

This repo requires `wlroots-0.19` to report Xwayland support:

```bash
pkg-config --variable=have_xwayland wlroots-0.19
```

The expected output is:

```text
true
```

If it prints `false`, the installed wlroots library was built without Xwayland.
Do not fix this by editing the `.pc` file. Rebuild and reinstall wlroots with
Xwayland enabled.

## 1. Install Xwayland build dependencies

On Debian 13:

```bash
sudo apt install libxcb-ewmh-dev libxcb-errors-dev xwayland
```

Useful checks:

```bash
for p in xcb xcb-composite xcb-ewmh xcb-icccm xcb-render xcb-res xcb-xfixes xwayland; do
    printf '%s ' "$p"
    pkg-config --exists "$p" && pkg-config --modversion "$p" || echo missing
done
```

## 2. Rebuild wlroots 0.19 with Xwayland

Use wlroots `0.19.1`, because this SwayFX tree depends on `wlroots-0.19`.

```bash
git clone --branch 0.19.1 https://gitlab.freedesktop.org/wlroots/wlroots.git /tmp/wlroots-0.19.1
cd /tmp/wlroots-0.19.1

meson setup build \
  --prefix /usr/local \
  -Dxwayland=enabled \
  -Dexamples=false

ninja -C build
sudo ninja -C build install
sudo ldconfig
```

Confirm the host now sees the right wlroots:

```bash
pkg-config --modversion wlroots-0.19
pkg-config --variable=pcfiledir wlroots-0.19
pkg-config --variable=have_xwayland wlroots-0.19
```

Expected result:

```text
0.19.1
/usr/local/lib/x86_64-linux-gnu/pkgconfig
true
```

## 3. Rebuild SwayFX-Enhanced

Reconfigure from scratch so Meson re-detects the Xwayland-enabled wlroots:

```bash
cd "/media/creitin/External SSD/Docs/swayfx-enhanced"
meson setup --wipe build
ninja -C build
sudo ninja -C build install
```

This repo intentionally fails configuration if wlroots reports
`have_xwayland=false`.

## 4. Start Xwayland from the Sway config

The installed default config already contains:

```sway
xwayland force
```

If you use a personal config, add the same line near the top of:

```text
~/.config/sway/config
```

This starts the Xwayland server for compatibility. It should not force
Wayland-capable apps onto X11; the session launcher keeps toolkit defaults on
Wayland and leaves Xwayland for X11-only apps or explicit overrides.

## 5. Verify at runtime

After logging into the rebuilt SwayFX session:

```bash
swayfx-check-xwayland
echo "$DISPLAY"
pgrep -a Xwayland
swaymsg -t get_tree | grep '"shell": "xwayland"'
```

If the final command has no output, launch an X11 client first:

```bash
env GDK_BACKEND=x11 xeyes
```

Then run:

```bash
swaymsg -t get_tree | grep '"shell": "xwayland"'
```
