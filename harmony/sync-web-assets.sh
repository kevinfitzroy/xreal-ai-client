#!/usr/bin/env bash
# 把共享 Web UI 资产(契约源 = android assets)同步进 HarmonyOS rawfile。
# index.html 等只在 android/app/src/main/assets/ 改一次,改完跑本脚本同步过来(与 iOS 同策略)。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/android/app/src/main/assets"
DST="$ROOT/harmony/app/entry/src/main/resources/rawfile"
for f in index.html xterm.js xterm.css addon-fit.js addon-webgl.js addon-search.js addon-unicode11.js meslo-powerline.otf sarasa-term.ttf; do
  cp "$SRC/$f" "$DST/$f"
  echo "synced $f"
done
echo "done -> $DST"
