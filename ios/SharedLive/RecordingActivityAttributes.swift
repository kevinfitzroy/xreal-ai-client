import ActivityKit
import Foundation

/// 终端页录音的 Live Activity 属性(issue #23 P2:锁屏 / 灵动岛显示录音进行中)。
/// **主 app 与 RecordingWidget extension 共编译这一份**(SharedLive/),两端类型必须完全一致。
///
/// `ContentState.startedAt` 给 widget 的 `Text(timerInterval:)` 自走计时用 —— 无需 app 每秒 push 更新,
/// 锁屏后 widget 自己滚秒,省电也省去后台推送。
struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var startedAt: Date
        var projectName: String?
    }
}
