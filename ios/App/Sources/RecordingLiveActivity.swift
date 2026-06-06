import ActivityKit
import Foundation

/// 终端页录音的 Live Activity 控制(issue #23 P2)。锁屏 / 灵动岛显示「正在录音 + 计时」,缓解息屏后
/// 「到底还在不在录」的焦虑。展示型(无交互按钮),解锁后回 app 上滑停止。
///
/// 配合 `UIBackgroundModes: audio`(Info.plist)—— 否则息屏 app 被挂起、录音会停,Live Activity 也就名不副实。
/// 计时靠 widget 端 `Text(timerInterval:)` 自走,这里只在 开始/结束 各发一次,不做每秒 push。
enum RecordingLiveActivity {
    private static var current: Activity<RecordingActivityAttributes>?

    /// 锁定录音时开始(必须在前台调 —— 用户刚做完上滑手势,满足)。用户关了 Live Activities 则静默跳过。
    static func start(projectName: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AgentLog.info("rec", "live activities disabled; skip")
            return
        }
        end()   // 防御:已有未收的先收掉
        let state = RecordingActivityAttributes.ContentState(startedAt: Date(), projectName: projectName)
        do {
            current = try Activity.request(
                attributes: RecordingActivityAttributes(),
                content: .init(state: state, staleDate: nil))
            AgentLog.info("rec", "live activity started")
        } catch {
            AgentLog.error("rec", "live activity start failed: \(error)")
        }
    }

    /// 录音结束 / 取消 → 立即收起。
    static func end() {
        guard let a = current else { return }
        current = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// 清理上次进程残留(崩溃/被杀后可能有孤儿活动还挂在锁屏)。app 启动时调一次。
    static func endStale() {
        for a in Activity<RecordingActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        current = nil
    }
}
