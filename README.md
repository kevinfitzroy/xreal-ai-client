# xreal-ai-client

Android App,把 SSH client + 漂亮 terminal UI + 语音输入塞进同一个进程,跑在 XREAL One Pro AR 眼镜 + Beam Pro 上,操作远程服务器的 Claude Code。

**现状**:Phase 0 完成,核心流程已在 Beam Pro 真机打通(列表 → 开 project → 真 SSH 终端 + 中英文/powerline 显示);代客安装 (Valet Setup) 已落地。详见 [`ROADMAP.md`](ROADMAP.md)。

---

## 代客安装 (Valet Setup) — 本项目的特色

**这个 app 你不能亲手安装,只能让 AI agent 替你装。这是设计,不是缺陷。**

它跑在 AR 眼镜 + 一个 6 键手柄上,**故意不做任何设置 UI** —— 在眼镜里手输 SSH 地址、端口、私钥是地狱。所以"初始化"这件事被彻底外包给 AI:你用大白话把诉求交给 agent,SSH key 生成、配置下发、host 端部署全是它们的事。我们把这个模式叫 **代客安装 (Valet Setup)**。这是一个**必须有 AI agent 参与**的工作流,本就不适合人亲自操办。

整套系统由你的两位「AI 班底」伺候:

| 角色 | 在哪 | 干什么 |
|---|---|---|
| **Valet(代客)** | 你的笔记本 | 经 `adb` 替你完成 app 初始化:生成专用 key、下发配置、触发导入 |
| **Maestro** | 你的服务器 | 常驻 base path,按你的语音诉求建项目、起 session、维护项目清单 |

你只负责动嘴。

```
   ┌─ "I'll set it up myself." ──── said no user of this app, ever ─┐
   └────────────────────────────────────────────────────────────────┘

     YOU, in AR glasses:   "set it up."  ──┐   ...then sips coffee.
                                            │
                                            ▼
     VALET   (Claude Code on your laptop)
        - generates a dedicated SSH key
        - adb push  ──[ key + host config ]──►   THE APP  (the phone)
                                                    - no settings UI. it just obeys.
                                                    - imports key to private storage
                                                          │
                                                          │ ssh
                                                          ▼
     MAESTRO (Claude Code on your server)
        - mkdir / tmux / claude
        - runs your fleet, maintains the project list
        - "the ensemble is ready, maestro."

     YOU: still sipping coffee. did literally nothing. perfect.
```

**怎么用**:
1. 在笔记本上开一个 Claude Code,把 [`docs/agent-setup-guide.md`](docs/agent-setup-guide.md) 丢给它 —— 它就是你的 Valet。
2. 它会问你 host 信息、生成专用 key、经 `adb` 装好 app,并把 [`docs/orchestrator-CLAUDE.md`](docs/orchestrator-CLAUDE.md) 部署成你服务器上的 Maestro。
3. 之后戴上眼镜,对着 Maestro 说"帮我搞个做 X 的项目",它建目录、起 agent、更新列表。

**安全**:每台 host 一把**专用、一次性**的 SSH key,在你笔记本上生成,经 USB(`adb`)直送 app 私有存储(`600`)。中转区里那把世界可读的临时 key,由 Valet 在确认导入后 `adb shell rm` 清掉(app 在 SELinux 下删不了)。全程不碰你的主 key。

---

## 目录结构

```
.
├── CLAUDE.md                              ← Claude Code session 主入口(必读)
├── README.md                              ← 本文件
├── ROADMAP.md                             ← 分级需求跟踪(P0 核心 / P1 / P2)
├── docs/
│   ├── background.md                      ← 项目背景:为什么要做这个 App
│   ├── architecture.md                    ← 完整架构 + 可编译代码骨架
│   ├── agent-setup-guide.md               ← 「代客 (Valet)」引导:笔记本 agent 经 adb 装 app
│   ├── orchestrator-CLAUDE.md             ← Maestro 的 CLAUDE.md:部署到 host base path
│   ├── xreal-project.sh                   ← Maestro 的建项目助手(按类型一键起环境 + 写 manifest)
│   ├── projects.example.json              ← 项目清单 manifest 示例(给 Maestro 照抄)
│   ├── session-persistence-options.md     ← tmux 替代方案调研(推荐 abduco)
│   ├── stage-a-experiments.md             ← Stage A 实验设计 + pass/fail + fallback
│   └── upstream-docs-index.md             ← 上游 term-on-demand repo docs 导航
└── android/                               ← Android Studio 项目
```

---

## 开始

启动 Claude Code session,它会自动读 `CLAUDE.md`,然后按 §4 "Phase 0 完成清单" 一步步推进。

如果你是人类直接想看,推荐阅读顺序:
1. `docs/background.md` — 这个项目要解决什么问题
2. `docs/architecture.md` — 怎么实现
3. `docs/stage-a-experiments.md` — 怎么验证
4. `docs/session-persistence-options.md` — 服务端用什么(tmux / abduco / ...)

---

## 上游项目

本项目是 [`clawzhang89-bot/term-on-demand`](https://github.com/clawzhang89-bot/term-on-demand) 的具体实施。设计文档源头是上游 `docs/07-android-app-architecture.md`(PR #8)。

`docs/upstream-docs-index.md` 给了完整索引。

---

## License

待定。
