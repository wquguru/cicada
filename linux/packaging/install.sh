#!/bin/sh
set -e
src="$(cd "$(dirname "$0")" && pwd)"
lib="$HOME/.local/lib/cicada"; bin="$HOME/.local/bin"; share="$HOME/.local/share"
if [ "$1" = "--remove" ]; then
  rm -rf "$lib" "$bin/cicada" "$share/applications/com.wquguru.cicada.desktop" "$share/icons/hicolor/scalable/apps/cicada.svg" \
         "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/com.wquguru.cicada.desktop"
  python3 - <<'PY' 2>/dev/null || true
from gi.repository import Gio
schema = "org.gnome.settings-daemon.plugins.media-keys"
if Gio.SettingsSchemaSource.get_default().lookup(schema, True):
    keys = Gio.Settings.new(schema)
    ours = {"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/%s/" % n for n in ("cicada", "cicada-speak")}
    keys.set_strv("custom-keybindings", [p for p in keys.get_strv("custom-keybindings") if p not in ours])
    Gio.Settings.sync()
PY
  echo "Cicada removed."; exit 0
fi
missing=""
python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null || missing="$missing python3-gi gir1.2-gtk-3.0"
python3 -c 'import ctypes.util, sys; sys.exit(0 if ctypes.util.find_library("pulse-simple") else 1)' || missing="$missing libpulse0"
if [ -n "$missing" ]; then echo "Cicada needs:$missing  (sudo apt install$missing)"; exit 1; fi
[ "$1" = "--check" ] && exit 0
rm -rf "$lib" && mkdir -p "$lib" "$bin" "$share/applications" "$share/icons/hicolor/scalable/apps"
cp -R "$src/cicada" "$src/lproj" "$src/bin" "$lib/"
[ -f "$src/sample.wav" ] && cp "$src/sample.wav" "$lib/"
for d in models lib; do [ -d "$src/$d" ] && cp -R "$src/$d" "$lib/"; done
cp "$src/cicada.svg" "$lib/"
cp "$src/VERSION" "$lib/"
ln -sf "$lib/bin/cicada" "$bin/cicada"
sed "s|@BIN@|$lib/bin/cicada|" "$src/com.wquguru.cicada.desktop" > "$share/applications/com.wquguru.cicada.desktop"
cp "$src/cicada.svg" "$share/icons/hicolor/scalable/apps/cicada.svg"
gtk-update-icon-cache -q "$share/icons/hicolor" 2>/dev/null || true
echo "Cicada installed: open it from the app grid (知了 / Cicada)."
