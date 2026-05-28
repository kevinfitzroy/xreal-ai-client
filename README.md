# xreal-ai-client

Android App,把 SSH client + 漂亮 terminal UI + 语音输入塞进同一个进程,跑在 XREAL One Pro AR 眼镜 + Beam Pro 上,操作远程服务器的 Claude Code。

**当前阶段**:Phase 0 — Mac 上脚手架 + Android Emulator 验证(不需要物理设备)

---

## 目录结构

```
.
├── CLAUDE.md                              ← Claude Code session 主入口(必读)
├── README.md                              ← 本文件
├── docs/
│   ├── background.md                      ← 项目背景:为什么要做这个 App
│   ├── architecture.md                    ← 完整架构 + 可编译代码骨架
│   ├── session-persistence-options.md     ← tmux 替代方案调研(推荐 abduco)
│   ├── stage-a-experiments.md             ← Stage A 实验设计 + pass/fail + fallback
│   └── upstream-docs-index.md             ← 上游 term-on-demand repo docs 导航
└── android/                               ← Android Studio 项目(Phase 0 待 init)
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
