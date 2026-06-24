#!/usr/bin/env bash
# build-ios.sh — build the optional iOS Singboxbridge.framework for SSH-over-443.
#
# 替代 xray-bridge/build-ios.sh(iOS 隧道引擎从 xray-core 换成 sing-box,见 issue #46)。
#
# Output:
#   ios/App/Frameworks/Singboxbridge.framework
#
# Xcode 工程有个「缺则 no-op」的 copy/sign build phase:framework 在 → Debug/Release 嵌进 app
# 的 Frameworks 目录,Swift 运行时 dlopen 动态加载;framework 不在 → 直连 host 照常,proxy host
# 以明确的「Singboxbridge not integrated」失败(优雅降级)。
#
# 前置:Go ≥ 1.24(sing-box v1.13 要 go1.24.7;本机 go1.25 满足)、gomobile/gobind 在 PATH、能翻墙拉 sing-box。
# 用法:  cd singbox-bridge && ./build-ios.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v gomobile >/dev/null || { echo "✗ gomobile not in PATH" >&2; exit 1; }

# ── toolchain + 代理硬化(踩过两个坑)─────────────────────────────────────────
# golang.org/x/mobile(gomobile binding 运行时)要 go≥1.25.0 → `go get -tool` 把本模块 go 指令抬到
# 1.25.0。两个坑:
#   ① GOTOOLCHAIN=auto 时 gomobile 内部子进程会去下**非法**的 "go1.25"(无 patch)→ toolchain not available;
#   ② gomobile 内部 `go mod tidy` 逐个走 sumdb(经 goproxy.cn 镜像)校验间接依赖,该端点常 504。
# 解法:把本机**已缓存的 go1.25.x toolchain 当 GOROOT** + GOTOOLCHAIN=local(toolchain 不再被当可下载
# 模块 → 不触发"下 go1.25"也不触发 sumdb 校验它)+ GOSUMDB=off(跳过 sumdb 远程 tile;go.sum 已锁哈希)。
TC_DIR="$(ls -d "$HOME"/go/pkg/mod/golang.org/toolchain@*go1.25*darwin-* 2>/dev/null | sort -V | tail -1)"
if [ -n "$TC_DIR" ] && [ -x "$TC_DIR/bin/go" ]; then
  export GOROOT="$TC_DIR"; export GOTOOLCHAIN=local; export PATH="$GOROOT/bin:$PATH"
  echo "→ GOROOT=$GOROOT (GOTOOLCHAIN=local, $("$GOROOT/bin/go" version | awk '{print $3}'))"
else
  export GOTOOLCHAIN="${GOTOOLCHAIN_PIN:-go1.25.0}"
  echo "→ 未找到缓存的 go1.25 toolchain;退回 GOTOOLCHAIN=$GOTOOLCHAIN(可能需联网下)"
fi
export GOSUMDB=off
export GOFLAGS="${GOFLAGS:-} -mod=mod"

# Claude 环境无网络 → go.sum 不随仓库提交;首次 build 在你本机 tidy 出来(之后请提交 go.mod/go.sum)。
if [ ! -f go.sum ]; then
  echo "→ go.sum 缺失,首次 build:go mod tidy(拉 sing-box 全量依赖,几分钟)…"
  go mod tidy
fi
echo "→ go mod download(version pinned in go.mod)…"
go mod download
echo "→ locked sing-box:$(go list -m github.com/sagernet/sing-box)"

# 关键 build tag:reality 的 uTLS 指纹(fp=chrome)依赖 `with_utls`,缺了 utls.enabled 配置会报错。
# tun/quic/wireguard/clash-api 都不需要 → 不加对应 tag,缩体积。
TAGS="with_utls"

gomobile init
OUT="../ios/App/Frameworks"
mkdir -p "$OUT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/singboxbridge-ios.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
echo "→ gomobile bind (tags: $TAGS) → $TMP/Singboxbridge.xcframework(sing-box 是大包,十几分钟)…"
gomobile bind -target=ios -tags "$TAGS" -trimpath -ldflags="-buildid=" -o "$TMP/Singboxbridge.xcframework" .

SLICE="$TMP/Singboxbridge.xcframework/ios-arm64/Singboxbridge.framework"
if [ ! -d "$SLICE" ]; then
  echo "✗ ios-arm64/Singboxbridge.framework not found in generated xcframework" >&2
  find "$TMP/Singboxbridge.xcframework" -maxdepth 3 -type d >&2
  exit 1
fi

# gomobile 的 iOS framework slice 是静态库。app 用 dlopen 懒加载 → 直连 host 在 bridge 缺失时仍能
# build/run。把静态库包成真正的 dynamic framework 以便嵌入。
# 链接的系统 framework 与 xray 版一致;若 sing-box 链接报缺符号,在这里补 -framework。
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
DYLIB="$TMP/Singboxbridge.framework"
mkdir -p "$DYLIB"
clang -target arm64-apple-ios17.0 -isysroot "$SDK" \
  -dynamiclib -all_load "$SLICE/Singboxbridge" \
  -framework Foundation -framework Security -framework Network -lresolv \
  -install_name @rpath/Singboxbridge.framework/Singboxbridge \
  -o "$DYLIB/Singboxbridge"
cp "$SLICE/Info.plist" "$DYLIB/Info.plist"
cp -R "$SLICE/Headers" "$DYLIB/Headers"
cp -R "$SLICE/Modules" "$DYLIB/Modules"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 17.0" "$DYLIB/Info.plist" 2>/dev/null || true

rm -rf "$OUT/Singboxbridge.framework"
cp -R "$DYLIB" "$OUT/Singboxbridge.framework"

echo ""
echo "✓ done: $OUT/Singboxbridge.framework"
du -sh "$OUT/Singboxbridge.framework"
echo "→ sha256:"
find "$OUT/Singboxbridge.framework" -type f -maxdepth 1 -print0 | xargs -0 shasum -a 256
