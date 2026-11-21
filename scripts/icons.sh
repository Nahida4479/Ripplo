#!/usr/bin/env bash
# Renders app icons from public/*.svg. Needs rsvg-convert + magick.
set -euo pipefail
cd "$(dirname "$0")/.."
RES=android/app/src/main/res
render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

for spec in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r d s a <<<"$spec"
  out="$RES/mipmap-$d"; mkdir -p "$out"
  render public/icon.svg "$s" "$out/ic_launcher.png"
  magick "$out/ic_launcher.png" \( -size "${s}x${s}" xc:none -fill white \
    -draw "circle $((s/2)),$((s/2)) $((s/2)),0" \) -alpha set -compose DstIn -composite \
    "$out/ic_launcher_round.png"
  render public/icon_android_foreground.svg "$a" "$out/ic_launcher_foreground.png"
  render public/icon_android_background.svg "$a" "$out/ic_launcher_background.png"
done

for f in ic_launcher ic_launcher_round; do
  cat > "$RES/mipmap-anydpi-v26/$f.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
XML
done

# iOS: 1024 opaque, no alpha
magick public/icon_ios.png -background white -alpha remove -alpha off -resize 1024x1024 \
  PNG24:ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png
