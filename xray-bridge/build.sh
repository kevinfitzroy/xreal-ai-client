#!/usr/bin/env bash
# build.sh — 从官方 xray-core 源码,用 gomobile 构建 Android AAR(SSH-over-443 隧道功能的核心)。
#
# 在哪跑:**你的 Mac**(能翻墙、能 go get xtls/xray-core)。Claude 的环境网络受限,build 这步只能人来。
# 产物:android/app/libs/xraybridge.aar(被 app/build.gradle.kts 的 fileTree 自动引入)。
#
# 前置(只需装一次):
#   1) Go ≥ 1.23           brew install go            # 验证: go version
#   2) Android NDK         Android Studio → SDK Manager → SDK Tools 勾 "NDK (Side by side)"
#                          装后路径形如 ~/Library/Android/sdk/ndk/<version>
#   3) gomobile + gobind:
#        go install golang.org/x/mobile/cmd/gomobile@latest
#        go install golang.org/x/mobile/cmd/gobind@latest
#        export PATH="$PATH:$(go env GOPATH)/bin"
#
# 用法:  cd xray-bridge && ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

# ── NDK 路径:优先环境变量,否则取 sdk/ndk 下最新一个 ──────────────────────────
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ] || {
  echo "✗ 找不到 NDK。在 Android Studio SDK Manager 装 'NDK (Side by side)',或 export ANDROID_NDK_HOME=..." >&2
  exit 1
}
export ANDROID_NDK_HOME
echo "→ NDK: $ANDROID_NDK_HOME"

command -v gomobile >/dev/null || { echo "✗ gomobile 不在 PATH。见本脚本头部前置 step 3。" >&2; exit 1; }

# ── 拉官方 xray-core 并锁版本 ────────────────────────────────────────────────
echo "→ go get xtls/xray-core@latest(需翻墙)…"
go get github.com/xtls/xray-core@latest
go mod tidy
echo "→ 锁定版本:$(go list -m github.com/xtls/xray-core)"

# ── gomobile bind:只打 arm64-v8a(Beam Pro X4100),androidapi 与 app minSdk 对齐 ──
gomobile init
OUT="../android/app/libs"
mkdir -p "$OUT"
echo "→ gomobile bind → $OUT/xraybridge.aar(几分钟,xray-core 是大包)…"
gomobile bind -target=android/arm64 -androidapi 26 -trimpath -ldflags="-buildid=" -o "$OUT/xraybridge.aar" .

echo ""
echo "✓ 完成: $OUT/xraybridge.aar"
ls -lh "$OUT/xraybridge.aar"
echo "→ 记录 sha256(锁定二进制,提交时附上):"
shasum -a 256 "$OUT/xraybridge.aar"
