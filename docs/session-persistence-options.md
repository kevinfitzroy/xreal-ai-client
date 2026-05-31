# 服务端 SSH Session 驻留方案调研

> 用户在过往 tmux 使用中体感不好:**卡** + **历史信息有问题**。这份文档评估替代方案,并给出对本项目场景的推荐。
>
> **当前结论(2026-05-28 修订,已落地)**:产品从「单终端 SSH client」升级成「AI agent 集群指挥台」后,**agent 类 project 改用 tmux** —— 状态探测(`capture-pane`)、copy-mode 半页翻页、以及 Claude Code 状态上报 hooks 都需要一个真 tmux session,abduco 无等价能力。**纯 SSH 场景(不需要探测/翻页)仍可用 abduco**(零 UI、零卡顿)。`SshConnection` 的启动命令本就可配,二者无缝切换。下文调研保留 abduco 视角作为「纯 SSH」分支的依据;「卡」痛点在 agent 路径上靠精简 tmux 配置(见 §4.1)+ client 端 xterm.js scrollback 化解。

---

## 1. 我们需要什么(本项目场景)

回到本项目的实际需求,只需要这几条:

1. **Session 不死** — SSH 断了之后,服务端 `claude code` 进程还在,重连后能 attach 回来
2. **响应快** — AR 眼镜下任何卡顿都被放大,延迟敏感
3. **历史能查** — 看之前几小时的 shell 输出 / `claude code` 对话
4. **不要 splits** — 我们就一个 session 跑 `claude code`,不需要分屏
5. **不要 status bar / 装饰** — 屏幕空间宝贵,任何额外占行都不想要

**关键洞察**:本项目 client 端是自己写的 App,**xterm.js 自带 10000 行 scrollback + 搜索 + 复制 + 导出**(`SerializeAddon` 还可以导出整个 buffer)。也就是说**"历史信息"这件事在客户端就解决了**,服务端 multiplexer 不需要再负担这个职责 — 服务端只需要"session 不死"这一件事。

这反转了选择空间:**不需要 tmux/zellij 这类"全功能 multiplexer",一个最简的 detach/attach 工具就够**。

---

## 2. 候选方案概览

按"复杂度"从高到低排:

| 类别 | 工具 | 一句话 | 内存 | 启动延迟 | 项目契合度 |
|---|---|---|---|---|---|
| 全功能 multiplexer | **tmux** | 经典,功能多,生态成熟 | 5-15 MB | 即时 | ⚠️ 卡 + 配置成本 |
| 全功能 multiplexer | **zellij** | Rust 写,UI 现代,modal hints,WASM 插件 | 22 MB | 即时 | ❌ 比 tmux 更慢(渲染慢 4x) |
| 全功能 multiplexer | **GNU screen** | 比 tmux 更老,功能少 | <5 MB | 即时 | ⚠️ 历史悠久但 UX 老 |
| 极简 detach/attach | **dtach** | 最小,~1k LoC,极快 | <1 MB | 即时 | ⭐ 强契合 |
| 极简 detach/attach | **abduco** | dtach 现代替代,active maintained,ISC | <1 MB | 即时 | ⭐⭐ 最强契合 |
| SSH 连接层 | **mosh** | UDP-based,断网自动重连,**不做 session 驻留** | 客户端轻 | 即时 | ❌ 解决的是不同问题 |
| SSH 连接层 | **Eternal Terminal (ET)** | TCP-based 自动重连,**不做 session 驻留** | 服务端 ~5 MB | 即时 | ⚠️ 跟 abduco/tmux 搭配用 |
| 进程救援 | **reptyr** | 把已跑的进程"附身"到新终端,一次性救援 | — | — | ❌ 不是常驻方案 |

---

## 3. 对用户痛点的深度分析

### 痛点 1:tmux 卡

可能原因(按频率):
- **status bar 频繁刷新**:默认每秒一次,有 plugins 算 git / CPU / battery 状态时更卡
- **scrollback buffer 太大**:默认 2000 行 × 多个 panes,内存占用快速膨胀(到 100 MB+)
- **mouse mode 切换的渲染开销**
- **复杂 plugins**(tpm + 装一堆) — 启动慢、运行卡
- **client side rendering**(SSH 客户端跑 tmux,服务端只是普通 shell)— 在 Android 上跑 tmux 客户端会更卡

如果继续用 tmux,**调优配置**能解决 80% 卡顿(见 §6 推荐配置),但仍需要维护一份 config。

### 痛点 2:历史信息问题

可能含义:
- **copy-mode 不直观**(vi/emacs 两套 binding 都有学习成本)
- **scrollback 没法导出搜索**(只能在 tmux 内部 search-backward)
- **search 体验远不如普通编辑器**(没有 fuzzy、没有 grep)

**这个痛点在本项目里其实不存在**:
- 客户端 xterm.js 自带 10000 行 scrollback
- xterm.js 内置 `SearchAddon` — 直接搜
- xterm.js 内置 `SerializeAddon` — 导出整个 buffer 到字符串
- 我们可以在 WebView 里写一个"按 Ctrl+F 调出搜索框"的 UI,体验跟浏览器一样

也就是说,**只要 client 端 xterm.js scrollback 够用,服务端 multiplexer 的 history 功能就是冗余的**。

---

## 4. 候选方案详细对比

### 4.1 tmux(继续用,但精简配置)

**优**:
- 已经在用,熟悉
- 默认存在于几乎所有 Linux distro
- 文档/社区/答疑最丰富
- `claude code --resume` 配 tmux 是社区主流做法

**劣**:
- 默认配置在我们场景下有 overhead
- 跨平台一致性差(macOS 上 tmux 行为略不同)

**推荐配置**(`~/.tmux.conf`,精简版):

```tmux
# 不要 status bar(节省一行 + CPU)
set -g status off

# scrollback:agent 路径实际用 50000(往回翻历史输出);纯终端可调小
set -g history-limit 50000

# 半页翻页(agent 路径):Shift+↑/↓ 进 copy-mode,走 root 表 Claude Code 收不到 → 不冲突
bind -n S-Up   "copy-mode ; send-keys -X halfpage-up"
bind -n S-Down 'if -F "#{pane_in_mode}" "send-keys -X halfpage-down"'

# 关闭 mouse(我们用键盘 + xterm.js 自己的 mouse)
set -g mouse off

# 关闭所有 plugins
# (不加载 tpm,删 .tmux/plugins/)

# escape 时间设短(默认 500ms,影响 Esc 键体感)
set -sg escape-time 10

# session detach 自动 destroy(我们一个 session 用)
set -g destroy-unattached on
```

启动:`tmux new -A -s dev "claude code --resume"`

### 4.2 abduco(纯 SSH 场景推荐 ⭐)

**优**:
- 极简(<1k LoC),零 status bar / panes / mouse 等"多余" 功能
- 内存占用 < 1 MB
- 启动即时,响应零感知延迟
- 完美契合"我只想要 session 不死"的需求
- ISC license,active maintained([GitHub](https://github.com/martanne/abduco))

**劣**:
- 不在 Debian/Ubuntu 默认源(需要 `apt install abduco` — 实际上 Ubuntu 24.04+ 已经有)
- 没有内置 scrollback(但我们 xterm.js 已经有)
- 没有 splits(我们不需要)
- 远不如 tmux 流行,文档少

**部署**:

```bash
# Ubuntu 24.04+
sudo apt install abduco

# 或者从源码 build(超简单):
git clone https://github.com/martanne/abduco
cd abduco && make && sudo make install
```

**启动**:`abduco -A dev claude code --resume`
- `-A` = attach if exists, create if not(类似 `tmux new -A`)
- 断开后重连:`abduco -A dev claude code --resume`(同一命令)

**这是本项目最契合的选择**。

### 4.3 zellij(✗ 不推荐)

**优**:
- UI 最现代(modal hints、自带 tab/pane 装饰)
- Rust 写,稳定性好
- WASM 插件生态

**劣** — 对本项目而言这些都是劣势:
- 内存占用 22 MB(比 tmux 高 4x)
- 100 panes 渲染基准:zellij fullscreen toggle 平均 183ms,tmux 平均 48ms(慢 4x)— 印证用户"卡"痛点
- 默认显示一堆 hint / tab bar,占空间
- 配置 + 学习成本高

**用户的"卡"痛点切换到 zellij 几乎肯定会变得更差,不是更好**。

### 4.4 GNU screen(⚠️ 可用但老)

跟 abduco 类似定位(session 驻留 + 简单),但:
- UX 古老(escape key 是 `Ctrl+a`,跟 readline 冲突;切 split 复杂)
- 不再积极开发
- 比 abduco 大,功能多但你都不用

如果服务端不允许装 abduco,screen 是兜底。

### 4.5 dtach(可用)

abduco 的"前身",类似但更老。abduco 是 dtach 的现代重写,如果你能装 abduco,就不需要 dtach。

### 4.6 mosh(⚠️ 解决的是不同问题)

mosh 不做 session 驻留,做的是"SSH 断网自动重连 + local echo"。

- mosh 改进的是**网络层**(UDP-based,断网恢复后秒级重连;打字时本地预测,屏蔽 RTT)
- 但 mosh **不保留 session** — mosh 进程死了 session 也没了

**典型组合**:`mosh ... -- tmux new -A -s dev` 或 `mosh ... -- abduco -A dev ...`

**对本项目**:我们用 sshj(Java SSH 库)直接连 TCP SSH,**不能用 mosh**(mosh 是另一套协议)。所以 mosh 在本项目不可用。

我们的"断网"问题靠 sshj 的重连机制 + abduco 的 session 驻留来解决,**不需要 mosh**。

### 4.7 Eternal Terminal (ET)(⚠️ 跟 mosh 类似 trade-off)

- ET 是个 SSH 替代协议,TCP-based,session 内置 reconnect
- 比 mosh 优势:支持 tmux control mode,所以 tmux 体验完整
- 但跟 mosh 一样需要服务端装 daemon,客户端用专门的 `et` 二进制
- **同样不能跟 sshj 直接配合**(协议不同)

不适合本项目。

### 4.8 reptyr(救援工具,不是常驻方案)

把已跑的进程从一个终端"reparent"到另一个。一次性救命用(忘了 tmux 跑的命令,临时把它移过来),不是日常 session 驻留方案。

---

## 5. 推荐:按场景二分 —— agent 类用 tmux,纯 SSH 用 abduco

产品升级为「agent 集群指挥台」后,驻留方案按 project 类型二分:

### 5a. agent 类 project(主路径)→ **tmux**

```
服务端(每个 agent 一个 session):
  tmux -u -f <精简conf> new -A -s <session>   # app 用此命令 cold-start;-A = attach if exists
  # session 内跑 claude code;Maestro 经 xreal-project.sh 建,带 -x200 -y50 防袖珍尺寸首连重绘
```

**为什么 agent 类必须 tmux(abduco 做不到)**:
1. **状态探测**:列表卡片要显示各 agent「working/waiting」+ 时长,早期靠 `tmux capture-pane -p` 抓屏(现已改 hooks 事件驱动,但 hooks 仍需要一个常驻 tmux session 承载 Claude Code)
2. **半页翻页**:Shift+↑/↓ → tmux root 表 `bind -n S-Up/S-Down` 进 copy-mode 半页滚(abduco 无 copy-mode)
3. **scrollback**:`set -g history-limit 50000`(默认 2000),配合 client 端 xterm.js 往回翻

「卡」痛点在此路径上靠精简 conf 化解(见 §4.1 + §6 配置):无 status bar、无 mouse、无 plugins、escape-time 短。

### 5b. 纯 SSH project(不需探测/翻页)→ **abduco**(可选)

```
服务端:
  abduco -A dev <command>          # 零 UI、零卡顿,< 1 MB

客户端(我们的 Android App):
  xterm.js scrollback + SearchAddon(Ctrl+F)+ SerializeAddon(可选导出)
```

不需要状态探测 / copy-mode 的纯终端场景,abduco 仍是最契合的极简选择;`SshConnection.startupCommand` 默认即 `abduco -A dev bash`,改一行配置就切到 tmux。

**两路共同点**:SSH 协议层都用 sshj 直连(无需 mosh/ET);断网靠 sshj 重连 + 服务端 session 还在 → 重连后 `-A` 立刻回到原状。

---

## 6. Fallback 计划

如果某条原因 abduco 不可用,按优先级 fallback:

1. **服务端没法装 abduco** → 退到 `screen -dRR dev claude code --resume`(几乎所有 Linux 都装好了)
2. **screen 也不行**(罕见) → 退到精简 tmux 配置(§4.1)
3. **完全不要 session 驻留(临时测试)** → 直接 `ssh ... -t "claude code --resume"`,断了就死

---

## 7. Phase 0 怎么处理

SSH 模块代码(已落地):

- **session 命令不硬编码**。`SshConnection.startupCommand` 是可配参数,默认 `abduco -A dev bash`(纯 SSH 兜底)
- **agent 类 project 实际用 tmux**:app cold-start 命令是 `tmux -u -f <conf> new -A -s <session>`,conf 里注入 `history-limit 50000` + copy-mode 翻页 binds(见 §5a / §6);Maestro 经 `xreal-project.sh` 建 session(带 `-x200 -y50`)
- 产品刻意无设置 UI(见 `CLAUDE.md` 理念),启动命令由 Valet/Maestro 在部署时定,不在眼镜里让用户选

代码上不需要为每个 multiplexer 写特殊处理 — 都是"一行启动命令"的差别。SSH PTY 协议本身不区分服务端跑的是 abduco 还是 tmux。

---

## 8. 一句话总结

**agent 类 project 用 tmux(状态探测 / copy-mode 翻页 / 状态 hooks 都依赖它,精简 conf 化解"卡");纯 SSH 场景可用 [abduco](https://github.com/martanne/abduco)(零 UI 零卡顿)。历史靠服务端 tmux scrollback(50000)+ 客户端 xterm.js scrollback 双保险。SSH 协议层走 sshj 直连,不需要 mosh/ET。`SshConnection.startupCommand` 可配,两者一行切换。**
