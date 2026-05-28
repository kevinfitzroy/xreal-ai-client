package io.github.kevinfitzroy.xrealclient

/**
 * 舰队/状态类体验功能的开关。这些是 P2 体验增强项(见 ROADMAP.md),已从核心流程搁置。
 * 核心流程(列表枚举 → 开真终端 → 键盘/语音)不依赖它们;把开关置 true 即接回。
 */
object FleetFeatures {
    /**
     * 实时状态刷新:周期性 SSH 跑 `tmux capture-pane` 探测 WORKING/WAITING/preview,推给列表。
     * 搁置原因:体验增强,不影响整体流程打通(列表静态枚举即可开真终端)。
     * 接回:置 true,[StatusPoller] 即恢复 5s 轮询(onStart/onStop 已挂好生命周期)。
     */
    const val LIVE_STATUS = false
}
