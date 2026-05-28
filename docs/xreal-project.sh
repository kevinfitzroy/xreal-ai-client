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
      claude|maestro) startup="claude";;
      agent)          startup="${XREAL_AGENT_CMD:-claude}";;
      ssh)            startup="";;   # 普通 shell,不自动起程序
    esac
  fi

  mkdir -p "$dir"
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "tmux session '$session' 已存在,复用(不重起程序)"
  else
    tmux -u new -d -s "$session" -c "$dir"          # -u 强制 UTF-8;否则中文/powerline 被降级成 _
    [ -n "$startup" ] && tmux send-keys -t "$session" "$startup" Enter
    echo "建好 '$session' (type=$type) @ $dir${startup:+  启动: $startup}"
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
  [ "${2:-}" = --kill ] && tmux kill-session -t "$session" 2>/dev/null || true
  manifest_remove "$session"
  echo "已从 manifest 移除 '$session'${2:+ 并杀掉 tmux session}"
}

case "${1:-}" in
  new) shift; cmd_new "$@";;
  ls)  cmd_ls;;
  rm)  shift; cmd_rm "$@";;
  *) echo "用法: $(basename "$0") {new|ls|rm} …  (详见脚本头部注释)" >&2; exit 2;;
esac
