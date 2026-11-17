#!/bin/bash
# Postaví Stahovak.app. S parametrem --install ji rovnou přesune do /Applications.
set -euo pipefail
cd "$(dirname "$0")"

for t in yt-dlp ffmpeg gallery-dl; do
  command -v "$t" >/dev/null || echo "Chybí $t, doinstaluj: brew install yt-dlp ffmpeg gallery-dl"
done

swift build -c release

APP="Stahovak.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stahovak "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# Ikona: Resources/icon.png (1024 px) -> AppIcon.icns
if [[ -f Resources/icon.png ]]; then
  SET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep -s - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Stahovák"' 2>/dev/null || true
  rm -rf "/Applications/$APP"
  mv "$APP" /Applications/
  touch "/Applications/$APP"   # ať Finder a Dock načtou novou ikonu
  echo "Nainstalováno: /Applications/$APP"
  open "/Applications/$APP"
else
  echo "Hotovo: $(pwd)/$APP  (./build.sh --install ji dá do Aplikací)"
fi
