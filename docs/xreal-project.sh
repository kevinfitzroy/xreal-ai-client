#!/usr/bin/env bash
# xreal-project.sh — Maestro 的项目创建/进入助手
#
# 部署:随 orchestrator-CLAUDE.md 一起放到 host 的 `<base>/.xreal/xreal-project.sh`(见 agent-setup-guide.md)。
# 用途:把"建工作目录 + 起对应执行环境的 tmux session + 登记进 manifest"封成一条命令,
#       让 Maestro(或人)一键拉起一个特定类型的项目,attach 即进入对应环境(如 Claude Code)。
#
# 为什么要这个脚本:每次手搓 mkdir/tmux/改 manifest 容易漏、容易写坏 JSON。这里把流程固定下来,
#       manifest 用 python3 原子读改写,session 幂等(已存在则复用)。
#
# 用法:
#   xreal-project.sh new <type> <session> [显示名] [--dir DIR] [--group G] [--cmd "启动命令"] [--attach]
#   xreal-project.sh ls
#   xreal-project.sh rm <session> [--kill]        # 从 manifest 移除;--kill 同时杀 tmux session
#
#   <type> ∈ claude | agent | ssh | maestro
#     claude  — Claude Code 项目(启动命令默认 `claude`)
#     agent   — 其它 AI agent(默认 `claude`,用 XREAL_AGENT_CMD 或 --cmd 改)
#     ssh     — 普通 shell(配角终端:日志/REPL/手工命令,不自动起程序)
#     maestro — Maestro 自己(host orchestrator,起在 <base>,每 host 一个,app 会 pin 到首位)
#
# 例:
#   xreal-project.sh new claude blog-rewrite "博客重写"            # 建 <base>/blog-rewrite + 起 claude
#   xreal-project.sh new ssh   prod-logs    --cmd 'tail -F /var/log/app/current'
#   xreal-project.sh new claude api --dir /srv/api --group work --attach   # 建完直接进 claude
set -euo pipefail

# base path:默认取脚本所在目录的父级(脚本在 <base>/.xreal/ 下);可用 XREAL_BASE 覆盖。
_sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${XREAL_BASE:-$([ "$(basename "$_sd")" = ".xreal" ] && dirname "$_sd" || echo "$_sd")}"
MANIFEST="$BASE/.xreal/projects.json"

command -v python3 >/dev/null || { echo "需要 python3 来安全地改 manifest" >&2; exit 1; }
command -v tmux    >/dev/null || { echo "需要 tmux" >&2; exit 1; }

# 把一条项目记录 upsert 进 manifest(按 session 去重),原子写。参数经环境变量传给 python3 避免拼接注入。
manifest_upsert() {
  mkdir -p "$BASE/.xreal"
  P_MANIFEST="$MANIFEST" P_SESSION="$1" P_NAME="$2" P_TYPE="$3" P_DIR="$4" P_GROUP="$5" P_STARTUP="$6" \
  python3 - <<'PY'
import json, os, tempfile
path = os.environ["P_MANIFEST"]
try:
    with open(path) as f: data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {"version": 1, "projects": []}
data.setdefault("version", 1); data.setdefault("projects", [])
entry = {"session": os.environ["P_SESSION"], "name": os.environ["P_NAME"],
         "type": os.environ["P_TYPE"], "dir": os.environ["P_DIR"],
         "group": os.environ["P_GROUP"], "startup": os.environ["P_STARTUP"]}
data["projects"] = [p for p in data["projects"] if p.get("session") != entry["session"]] + [entry]
d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
with os.fdopen(fd, "w") as f: json.dump(data, f, ensure_ascii=False, indent=2)
os.replace(tmp, path)   # 原子覆盖
PY
}

manifest_remove() {
  [ -f "$MANIFEST" ] || return 0
  P_MANIFEST="$MANIFEST" P_SESSION="$1" python3 - <<'PY'
import json, os, tempfile
path = os.environ["P_MANIFEST"]
with open(path) as f: data = json.load(f)
data["projects"] = [p for p in data.get("projects", []) if p.get("session") != os.environ["P_SESSION"]]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w") as f: json.dump(data, f, ensure_ascii=False, indent=2)
os.replace(tmp, path)
PY
}

# 给一个 AI-agent project 部署「状态上报」:Claude Code hooks → agent-status.sh 写 <base>/.xreal/status.json。
# session 名烤进 hook 命令(运行时零识别);app 一次性 cat status.json 显示 working/waiting/disconnected。
# 幂等:agent-status.sh 不存在才写;settings.json 用 python merge(保留已有键,只覆盖我们这几个事件)。
deploy_status_hooks() {
  local dir="$1" session="$2" xr="$BASE/.xreal"
  mkdir -p "$xr"
  if [ ! -x "$xr/agent-status.sh" ]; then
    cat > "$xr/agent-status.sh" <<'STATUS_SH'
#!/usr/bin/env bash
# Claude Code hook 调用:agent-status.sh <session> <state>。写 status/<session>.json(状态不变保留 since)+ 聚合 status.json。
set -euo pipefail
SESSION="${1:?}"; STATE="${2:?}"
DIR="$(cd "$(dirname "$0")" && pwd)/status"; mkdir -p "$DIR"
NOW=$(date +%s); F="$DIR/$SESSION.json"; SINCE=$NOW
if [ -f "$F" ]; then
  OLD=$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$F" || true)
  [ "$OLD" = "$STATE" ] && { SINCE=$(sed -n 's/.*"since":\([0-9]*\).*/\1/p' "$F"); [ -n "$SINCE" ] || SINCE=$NOW; }
fi
printf '{"session":"%s","state":"%s","since":%s,"updated":%s}' "$SESSION" "$STATE" "$SINCE" "$NOW" > "$F.tmp" && mv "$F.tmp" "$F"
AGG="$(dirname "$DIR")/status.json"
{ printf '{"timestamp":%s,"sessions":[' "$NOW"; first=1
  for s in "$DIR"/*.json; do [ -e "$s" ] || continue; [ $first = 1 ] || printf ','; cat "$s"; first=0; done
  printf ']}'; } > "$AGG.tmp" && mv "$AGG.tmp" "$AGG"
exit 0
STATUS_SH
    chmod +x "$xr/agent-status.sh"
  fi
  mkdir -p "$dir/.claude"
  P_XR="$xr" P_SESSION="$session" P_DEST="$dir/.claude/settings.json" python3 - <<'PY'
import json, os
xr=os.environ["P_XR"]; s=os.environ["P_SESSION"]; dest=os.environ["P_DEST"]
def cmd(state, matcher=None):
    h={"hooks":[{"type":"command","command":f"{xr}/agent-status.sh {s} {state}"}]}
    if matcher is not None: h["matcher"]=matcher
    return h
hooks={"UserPromptSubmit":[cmd("working")], "Stop":[cmd("waiting")],
       "SessionStart":[cmd("waiting")], "SessionEnd":[cmd("disconnected")],
       "Notification":[cmd("needs-permission","permission_prompt")]}
try:
    cfg=json.load(open(dest)); cfg = cfg if isinstance(cfg,dict) else {}
except Exception:
    cfg={}
cfg.setdefault("hooks",{}).update(hooks)
json.dump(cfg, open(dest,"w"), ensure_ascii=False, indent=2)
PY
  echo "状态 hooks → $dir/.claude/settings.json (session=$session)"
}

# 给 manifest 里所有 AI-agent project 部署/刷新状态 hooks(现有 project 一次性铺开;ssh 配角终端跳过)。
cmd_hooks() {
  [ -f "$MANIFEST" ] || { echo "(manifest 还不存在)"; return 0; }
  P_MANIFEST="$MANIFEST" python3 - <<'PY' | while IFS=$'\t' read -r type session dir; do
import json, os
for p in json.load(open(os.environ["P_MANIFEST"])).get("projects", []):
    print(f'{p.get("type","")}\t{p.get("session","")}\t{p.get("dir","")}')
PY
    case "$type" in claude|agent|maestro) [ -n "$dir" ] && deploy_status_hooks "$dir" "$session";; esac
  done
}

cmd_new() {
  local type="${1:-}" session="${2:-}"; shift 2 2>/dev/null || { echo "用法: new <type> <session> [显示名] [选项]" >&2; exit 2; }
  local name="" dir="" group="" startup="" attach=0
  case "$type" in claude|agent|ssh|maestro) ;; *) echo "type 必须是 claude|agent|ssh|maestro" >&2; exit 2;; esac
  [[ "$session" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "session 名只能用 [A-Za-z0-9_.-](会拼进 shell): $session" >&2; exit 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)   dir="$2"; shift 2;;
      --group) group="$2"; shift 2;;
      --cmd)   startup="$2"; shift 2;;
      --attach) attach=1; shift;;
      --*) echo "未知选项: $1" >&2; exit 2;;
      *) name="$1"; shift;;   # 第一个位置参数 = 显示名
    esac
  done
  [ -n "$name" ] || name="$session"
  # 工作目录:maestro 默认 base 本身,其余默认 <base>/<session>
  [ -n "$dir" ] || { [ "$type" = maestro ] && dir="$BASE" || dir="$BASE/$session"; }
  # 启动命令:type 决定默认(--cmd 覆盖)。这就是"不同类型如何进入各自执行环境"的关键映射。
  if [ -z "$startup" ]; then
    case "$type" in
      # maestro 自愈:claude 退出就自动重启(--continue 续上次对话)。保证每次进入都是 Claude Code,
      # 而不是误退后掉回 bash 没法管项目。sleep 1 防 claude 起不来时热循环。
      maestro) startup='while :; do claude --continue 2>/dev/null || claude; sleep 1; done';;
      claude)  startup="claude";;
      agent)   startup="${XREAL_AGENT_CMD:-claude}";;
      ssh)     startup="";;   # 普通 shell,不自动起程序
    esac
  fi

  mkdir -p "$dir"
  # AI-agent 项目:若工作目录还没有 CLAUDE.md,seed 一份「语音输入约定」(见 orchestrator-CLAUDE.md §6.2)。
  # 已有 CLAUDE.md(自带的 repo)则不动 —— 由 Maestro 自行把那段追加进去,别覆盖人家的。
  if { [ "$type" = claude ] || [ "$type" = agent ]; } && [ ! -e "$dir/CLAUDE.md" ]; then
    cat > "$dir/CLAUDE.md" <<'MD'
## 语音输入约定(xreal-ai-client)

本会话的用户用 AR 眼镜 + 语音操作。以 `🎤 ` 开头的用户消息 = **语音转写**,可能有同音字 / 断词 / 专名识别错误。

- **按意图理解,主动纠错**:别照字面执行明显是识别错的内容;不确定时先复述你的理解再动手。
- **专名反复错** → 主动提示用户:"要把『X』加进这个项目的热词表吗?" 用户同意后,让 Maestro 把它加进本项目 manifest 的 `hotwords`。热词表是 **project 级**的,各项目独立。
- 非 `🎤 ` 开头的消息是键盘输入,正常对待。
MD
    echo "seed 了语音约定 CLAUDE.md @ $dir/CLAUDE.md"
  fi
  # AI-agent 项目(都跑 claude):部署状态上报 hooks。下次 claude 启动即生效。
  case "$type" in claude|agent|maestro) deploy_status_hooks "$dir" "$session";; esac
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "tmux session '$session' 已存在,复用(不重起程序)"
  elif [ -n "$startup" ]; then
    # 启动命令作为 pane 命令直接跑(-u 强制 UTF-8)。**不用 send-keys** —— 它会和用户 shell 的
    # .zshrc/.bashrc 启动竞争,命令可能只被打到 prompt 没执行。命令退出后 `exec bash` 落回交互 shell
    # 保持 session 存活(maestro 的 loop 不会退,claude 项目退出后能在 shell 里手动重开)。
    # 先 source ~/.profile:tmux 起的是非 login shell,PATH 不含 ~/.local/bin
    # (claude native 安装默认落这里)。.bashrc 的 PATH 行在交互 guard 之后、非交互够不到,
    # 而 ~/.profile 无条件加 ~/.local/bin → 这样 maestro 保活循环才找得到 claude。
    tmux -u new -d -s "$session" -c "$dir" '. "$HOME/.profile" 2>/dev/null; '"$startup"'; exec bash'
    echo "建好 '$session' (type=$type) @ $dir  启动: $startup"
  else
    tmux -u new -d -s "$session" -c "$dir"          # 纯交互 shell(ssh 配角终端)
    echo "建好 '$session' (type=$type) @ $dir"
  fi
  manifest_upsert "$session" "$name" "$type" "$dir" "$group" "$startup"
  echo "已登记进 manifest: $MANIFEST"

  if [ "$attach" = 1 ]; then exec tmux attach -t "$session"; fi   # 一键进入该执行环境
  echo "进入: tmux attach -t '$session'   (或在 app 列表里打开)"
}

cmd_ls() {
  [ -f "$MANIFEST" ] || { echo "(manifest 还不存在)"; return 0; }
  P_MANIFEST="$MANIFEST" python3 - <<'PY'
import json, os
for p in json.load(open(os.environ["P_MANIFEST"])).get("projects", []):
    print(f'{p.get("type",""):8} {p.get("session",""):22} {p.get("name","")}')
PY
}

cmd_rm() {
  local session="${1:-}"; [ -n "$session" ] || { echo "用法: rm <session> [--kill]" >&2; exit 2; }
  # 保护 Maestro:它是 host 总入口,删了列表就没法回到你这儿下指令了
  [ "$session" = maestro ] && { echo "拒绝:maestro 是 host 总入口,不通过本脚本删除" >&2; exit 2; }
  [ "${2:-}" = --kill ] && tmux kill-session -t "$session" 2>/dev/null || true
  manifest_remove "$session"
  echo "已从 manifest 移除 '$session'${2:+ 并杀掉 tmux session}"
}

case "${1:-}" in
  new)   shift; cmd_new "$@";;
  ls)    cmd_ls;;
  rm)    shift; cmd_rm "$@";;
  hooks) cmd_hooks;;        # 给所有现有 AI-agent project 部署/刷新状态上报 hooks
  *) echo "用法: $(basename "$0") {new|ls|rm|hooks} …  (详见脚本头部注释)" >&2; exit 2;;
esac
