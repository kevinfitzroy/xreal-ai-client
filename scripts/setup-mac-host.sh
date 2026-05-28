#!/usr/bin/env bash
# 把"本机 Mac"配成 app 里的一个真 host(Maestro 驱动模型),用于持续测试。
#   - 在一个独立 base($HOME/xreal-test-base,不是项目仓库!)部署 Maestro:
#       CLAUDE.md(orchestrator)+ .xreal/xreal-project.sh + manifest
#   - 用 xreal-project.sh 建 maestro + 一个 ssh 配角项目(写进 manifest)
#   - adb reverse:手机 127.0.0.1:2222 → Mac sshd:22(app 的 SSH 终端 + manifest live-fetch)
#   - adb forward:Mac 127.0.0.1:8889 → 手机 app 输入直通端口(term-relay.py)
#   - push 私钥 + hosts.json(带 basePath),重启 app
# 幂等,可反复跑。reboot 后(/data/local/tmp 被清)重跑即可。
#
# 用法:scripts/setup-mac-host.sh
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
# UTF-8 locale:tmux server 按创建时的 locale 决定多字节处理;非 UTF-8 会把中文/powerline 降级成 `_`
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

ADB="${ADB:-adb}"
PKG="io.github.kevinfitzroy.xrealclient"
SSH_PORT=2222
RELAY_PORT=8889
KEY="$HOME/.ssh/xreal_phase0"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # 本仓库(取 docs/ 源)
BASE="${XREAL_BASE:-$HOME/xreal-test-base}"                    # Maestro 工作根(独立目录,别用仓库!)
ME="$(whoami)"

# 1) 私钥(没有就生成 + 授权本机)
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "xreal-test" >/dev/null
  echo "生成新 key: $KEY"
fi
grep -qF "$(cat "$KEY.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null || cat "$KEY.pub" >> "$HOME/.ssh/authorized_keys"

# 2) 部署 Maestro 到 base:CLAUDE.md + 助手脚本,然后用脚本建项目(写 manifest)
mkdir -p "$BASE/.xreal"
cp "$REPO_DIR/docs/orchestrator-CLAUDE.md" "$BASE/CLAUDE.md"
cp "$REPO_DIR/docs/xreal-project.sh"       "$BASE/.xreal/xreal-project.sh"
chmod +x "$BASE/.xreal/xreal-project.sh"
XREAL_BASE="$BASE" bash "$BASE/.xreal/xreal-project.sh" new maestro maestro "Maestro" >/dev/null
XREAL_BASE="$BASE" bash "$BASE/.xreal/xreal-project.sh" new ssh demo-logs "演示日志" \
  --cmd 'while :; do date; sleep 5; done' >/dev/null
echo "Maestro 就绪 @ $BASE,manifest:"
XREAL_BASE="$BASE" bash "$BASE/.xreal/xreal-project.sh" ls

# 3) adb 端口转发(幂等:重设即覆盖)
"$ADB" reverse "tcp:$SSH_PORT" "tcp:22"            >/dev/null
"$ADB" forward "tcp:$RELAY_PORT" "tcp:$RELAY_PORT" >/dev/null

# 4) push 私钥 + hosts.json(带 basePath,projects 只 seed maestro;其余由 app live-fetch manifest)
# 644:app 进程(非 shell uid)要能读这把 throwaway 本地测试 key。600 会 EACCES。
"$ADB" push "$KEY" /data/local/tmp/xreal_phase0 >/dev/null
"$ADB" shell chmod 644 /data/local/tmp/xreal_phase0
HOSTS_TMP="$(mktemp)"
cat > "$HOSTS_TMP" <<JSON
[
  {
    "name": "mac", "addr": "$ME@mac (本机)", "host": "127.0.0.1", "port": $SSH_PORT, "user": "$ME",
    "basePath": "$BASE",
    "keyPath": "/data/local/tmp/xreal_phase0",
    "projects": [
      { "session": "maestro", "name": "Maestro", "type": "maestro" }
    ]
  }
]
JSON
"$ADB" push "$HOSTS_TMP" /data/local/tmp/xreal_hosts.json >/dev/null
rm -f "$HOSTS_TMP"

# 5) 重启 app 让它读到新 hosts.json
"$ADB" shell am force-stop "$PKG" >/dev/null 2>&1 || true
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true

echo
echo "✅ 测试 host 'mac' 就绪。手机列表应出现:Maestro(首位)+ demo-logs。"
echo "   live-fetch 验证:在 Mac 上再建一个项目,然后在手机上 BACK 回列表,它应自动出现:"
echo "     XREAL_BASE='$BASE' bash '$BASE/.xreal/xreal-project.sh' new ssh test2 测试2 --cmd 'sleep 999'"
echo "   打字直通手机终端:  python3 scripts/term-relay.py"
