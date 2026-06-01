#!/usr/bin/env bash
# build-ios.sh — build the optional iOS xraybridge.framework for SSH-over-443.
#
# Output:
#   ios/App/Frameworks/Xraybridge.framework
#
# The Xcode project has a no-op-if-missing copy/sign build phase. If this framework exists,
# Debug/Release builds embed it into the app's Frameworks directory and Swift loads it
# dynamically at runtime. If it is absent, direct hosts still work and proxy hosts fail with
# an explicit "xraybridge not integrated" error.
set -euo pipefail
cd "$(dirname "$0")"

command -v gomobile >/dev/null || { echo "✗ gomobile not in PATH" >&2; exit 1; }

echo "→ go mod download(version pinned in go.mod)…"
go mod download
echo "→ locked xray-core:$(go list -m github.com/xtls/xray-core)"

gomobile init
OUT="../ios/App/Frameworks"
mkdir -p "$OUT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/xraybridge-ios.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
echo "→ gomobile bind → $TMP/Xraybridge.xcframework"
gomobile bind -target=ios -trimpath -ldflags="-buildid=" -o "$TMP/Xraybridge.xcframework" .

SLICE="$TMP/Xraybridge.xcframework/ios-arm64/Xraybridge.framework"
if [ ! -d "$SLICE" ]; then
  echo "✗ ios-arm64/Xraybridge.framework not found in generated xcframework" >&2
  find "$TMP/Xraybridge.xcframework" -maxdepth 3 -type d >&2
  exit 1
fi

# gomobile's iOS framework slice is a static archive. The app loads xraybridge lazily
# via dlopen so direct hosts can still build/run when the bridge is absent. Wrap the
# static archive into a real dynamic framework for embedding.
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
DYLIB="$TMP/Xraybridge.framework"
mkdir -p "$DYLIB"
clang -target arm64-apple-ios17.0 -isysroot "$SDK" \
  -dynamiclib -all_load "$SLICE/Xraybridge" \
  -framework Foundation -framework Security -framework Network -lresolv \
  -install_name @rpath/Xraybridge.framework/Xraybridge \
  -o "$DYLIB/Xraybridge"
cp "$SLICE/Info.plist" "$DYLIB/Info.plist"
cp -R "$SLICE/Headers" "$DYLIB/Headers"
cp -R "$SLICE/Modules" "$DYLIB/Modules"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 17.0" "$DYLIB/Info.plist" 2>/dev/null || true

rm -rf "$OUT/Xraybridge.framework"
cp -R "$DYLIB" "$OUT/Xraybridge.framework"

echo ""
echo "✓ done: $OUT/Xraybridge.framework"
du -sh "$OUT/Xraybridge.framework"
echo "→ sha256:"
find "$OUT/Xraybridge.framework" -type f -maxdepth 1 -print0 | xargs -0 shasum -a 256
