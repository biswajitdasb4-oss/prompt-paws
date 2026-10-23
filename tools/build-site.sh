#!/bin/sh
# Build the browser demo into build/site: the demo page plus the app's own renderer and panda.
# GitHub Pages runs this (.github/workflows/pages.yml). Local preview:
#   tools/build-site.sh && python3 -m http.server -d build/site 8000
set -eu
cd "$(dirname "$0")/.."
out=build/site
rm -rf "$out"
mkdir -p "$out/img" "$out/characters"
cp demo/index.html demo/style.css demo/demo.js "$out/"
cp demo/img/* docs/panda.png "$out/img/"
cp -R Resources/web "$out/web"
cp -R Resources/characters/panda "$out/characters/panda"
echo "site: $out ($(du -sh "$out" | cut -f1))"
