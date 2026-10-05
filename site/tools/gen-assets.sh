#!/usr/bin/env bash
# Regenerates the site's raster assets from the SVG logo with headless
# Chromium: og-card.png (1200x630), apple-touch-icon.png (180x180).
# Usage: site/tools/gen-assets.sh [chromium-binary]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
site=$(dirname "$here")
chrome=${1:-${CHROMIUM:-chromium}}
cp "$site/../assets/nestlo-logo.svg" "$site/logo.svg"
cp "$site/logo.svg" "$site/favicon.svg"
shot() { "$chrome" --headless=new --no-sandbox --hide-scrollbars --disable-gpu \
  --virtual-time-budget=4000 --window-size="$2" --screenshot="$3" "file://$1" >/dev/null 2>&1; }
shot "$here/og-card.html" 1200,630 "$site/og-card.png"
cat > "$here/.icon.html" <<HTML
<html><body style="margin:0;width:180px;height:180px;background:#0c1012;display:flex;align-items:center;justify-content:center">
<img src="../logo.svg" width="140" height="117"></body></html>
HTML
shot "$here/.icon.html" 180,180 "$site/apple-touch-icon.png"
rm -f "$here/.icon.html"
echo "assets written to $site"
