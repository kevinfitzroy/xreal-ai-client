#!/usr/bin/env bash
# 把"本机 Mac"配成 app 里的一个真 host,用于持续测试手机 terminal。
#   - 起两个 tmux session:main(跑真 claude)、shell(普通 bash)
#   - adb reverse:手机 127.0.0.1:2222 → Mac sshd:22(给 app 的 SSH 终端)
#   - adb forward:Mac 127.0.0.1:8889 → 手机 app 输入直通端口(给 term-relay.py)
#   - push 私钥 + hosts.json,重启 app
# 幂等,可反复跑。reboot 后(/data/local/tmp 被清)重跑即可。
#
# 用法:scripts/setup-mac-host.sh [项目目录(默认 ~/claude/xreal-ai-client)]
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
# UTF-8 locale:tmux server 按创建时的 locale 决定多字节处理;非 UTF-8 会把中文/powerline 降级成 `_`
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

ADB="${ADB:-adb}"
PKG="io.github.kevinfitzroy.xrealclient"
SSH_PORT=2222
RELAY_PORT=8889
KEY="$HOME/.ssh/xreal_phase0"
PROJ_DIR="${1:-$HOME/claude/xreal-ai-client}"
ME="$(whoami)"

# 1) 私钥(没有就生成 + 授权本机)
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "xreal-test" >/dev/null
  echo "生成新 key: $KEY"
fi
grep -qF "$(cat "$KEY.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null || cat "$KEY.pub" >> "$HOME/.ssh/authorized_keys"

# 2) tmux session(幂等):main 跑真 claude,shell 普通 bash
tmux has-session -t main 2>/dev/null || {
  tmux -u new -d -s main -x 200 -y 50
  tmux send-keys -t main "cd '$PROJ_DIR' && claude" Enter
  echo "起 tmux session 'main' + claude(于 $PROJ_DIR)"
}
tmux has-session -t shell 2>/dev/null || tmux -u new -d -s shell -x 200 -y 50

# 3) adb 端口转发(幂等:重设即覆盖)
"$ADB" reverse "tcp:$SSH_PORT" "tcp:22"            >/dev/null
"$ADB" forward "tcp:$RELAY_PORT" "tcp:$RELAY_PORT" >/dev/null

# 4) push 私钥 + hosts.json
# 644:app 进程(非 shell uid)要能读这把 throwaway 本地测试 key。600 会 EACCES。
"$ADB" push "$KEY" /data/local/tmp/xreal_phase0 >/dev/null
"$ADB" shell chmod 644 /data/local/tmp/xreal_phase0
HOSTS_TMP="$(mktemp)"
cat > "$HOSTS_TMP" <<JSON
[
  {
    "name": "mac", "addr": "$ME@mac (本机)", "host": "127.0.0.1", "port": $SSH_PORT, "user": "$ME",
    "keyPath": "/data/local/tmp/xreal_phase0",
    "projects": [
      { "session": "main",  "name": "claude-main", "type": "claude" },
      { "session": "shell", "name": "shell",       "type": "ssh" }
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
echo "✅ 测试 host 'mac' 就绪。手机列表里应出现 claude-main / shell。"
echo "   打字直通手机终端:  python3 scripts/term-relay.py"
echo "   (先在手机上进入 claude-main 终端,再在这边打字)"
