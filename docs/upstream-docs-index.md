# 上游 Repo Docs 索引

> 上游项目:[`clawzhang89-bot/term-on-demand`](https://github.com/clawzhang89-bot/term-on-demand) — "默认终端,按需 UI" 的整体理念 + 多轮迭代历史

本项目的设计是上游 `term-on-demand` 的具体实施。**你不需要主动去读上游 docs**(关键内容我已浓缩到本项目 `docs/` 下),但以下情况可以去读:

---

## 何时去读上游 docs

| 触发条件 | 去读哪个 | 用什么命令 |
|---|---|---|
| 用户提到具体 issue 号(#1, #4 等)| 对应 issue | `gh issue view N -R clawzhang89-bot/term-on-demand` |
| 用户提到具体 PR 号(#5, #6, #7, #8 等)| 对应 PR | `gh pr view N -R clawzhang89-bot/term-on-demand` |
| 你对某个架构决策的"为什么不 X" 有疑问 | `docs/06` 或 `docs/07` | `gh api ... contents/docs/...` 或本地 clone |
| 你对硬件选型(XREAL / Beam Pro / 8BitDo)有疑问 | `docs/02-hardware.md` 和 `docs/03-input.md` | 同上 |
| 用户提到"动态热词表" / ASR 优化 | `docs/03-input.md §热词持续优化` | 同上 |

---

## 上游 docs 文件清单

| 文件 | 主题 | 何时读 |
|---|---|---|
| [`README.md`](https://github.com/clawzhang89-bot/term-on-demand) | 项目总览 + 一句话哲学 | 想了解整体定位 |
| `docs/01-philosophy.md` | "默认终端,按需 UI" 的详细论述 | 想理解为什么选 terminal 不选 GUI |
| `docs/02-hardware.md` | XREAL One Pro vs Rokid / Beam Pro 选型 | 用户问"为什么是 XREAL 不是 Rokid" |
| `docs/03-input.md` ⭐ | 8BitDo Micro 键位 + 三种"语音→文本注入" 方案对比 + 动态热词表 | 用户问硬件配置 / 热词 / 注入方案 |
| `docs/04-workflow.md` | 各种场景下的端到端工作流 | 想理解完整使用流程 |
| `docs/05-roadmap.md` | TODO 路线图 | 想知道未来方向 |
| `docs/06-voice-interaction-execution.md` ⭐⭐ | 语音交互执行形态,多轮迭代的历史 | 想理解为什么 Voice Gateway / 剪贴板桥接等方案被取代 |
| `docs/07-android-app-architecture.md` ⭐⭐⭐ | **本项目的最终方案文档** — 完整架构 + 代码骨架 + Stage A | 等同于本项目 `docs/architecture.md` 的 source of truth |
| `docs/architecture.md` | 整体架构总图 | 系统级理解 |
| `ai/prompt-samples.md` | Claude Code / Codex CLI 的 prompt 模板 | 用户问 AI agent 怎么配 |
| `scripts/sysinfo` 等 | 服务端预制 HTML 生成脚本 | 跟本 App 正交,基本不需要 |

---

## 关键 issue / PR 历史(架构演进)

理解架构决策的"路径"远比看最终文档更有助于判断"能不能改" — 这些都不需要你主动看,但用户引用时你应该能找到:

| # | 类型 | 主题 | 状态 |
|---|---|---|---|
| #4 | issue | [design] 语音交互执行形态讨论:双端架构 + tmux send-keys + LLM 翻译层 | open(整个讨论的入口)|
| #5 | PR(merged)| 语音交互执行形态完整蓝图(Phase 0-4 双端架构)| merged |
| #6 | PR(merged)| 加边界声明对齐 docs/03 | merged |
| #7 | PR(closed)| 重写为剪贴板桥接 + Claude Code 主推(被 #8 取代)| closed |
| #8 | PR(open)| 单 app 闭环最终方案 ⭐ | open — **本项目就是这个 PR 的实施** |

---

## 上游身份 / 权限

- 上游 owner: `clawzhang89-bot`(不是你/用户)
- 用户在上游是 contributor,通过 PR 贡献文档
- **本项目的代码默认不 push 到上游** — 上游是文档/讨论仓库,具体代码可以独立 repo,或者在用户决定时再开新 PR 贡献回去

如果有一天需要 push 文档更新到上游:
- 用 `kevinfitzroy` GitHub 身份(详见 `CLAUDE.md §8`)
- fork 已经存在(`kevinfitzroy/term-on-demand`)
- 标准 PR 流程

---

## 跟本项目 `docs/` 的关系

本项目 `docs/` 是为 **cold-start session 高效启动**优化过的版本:

| 本项目 docs | 对应上游 |
|---|---|
| `docs/background.md` | 上游 `docs/01-philosophy.md` + `docs/02-hardware.md` + `docs/03-input.md` 的浓缩 |
| `docs/architecture.md` | 上游 `docs/07-android-app-architecture.md` 的浓缩(代码骨架部分基本复用)|
| `docs/stage-a-experiments.md` | 上游 `docs/07` §4 的展开 |
| `docs/session-persistence-options.md` | **本项目独有** — 用户在 Phase 0 准备阶段新增的需求 |
| `docs/upstream-docs-index.md` | 本文 — 上游 docs 的导航 |

也就是说,**本项目 `docs/` 是 self-contained 的**,你不必读上游就能完成 Phase 0 全部工作。
