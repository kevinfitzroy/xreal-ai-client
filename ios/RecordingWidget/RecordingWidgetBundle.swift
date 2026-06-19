import ActivityKit
import SwiftUI
import WidgetKit

/// RecordingWidget extension 入口。只含一个 Live Activity(终端页录音锁屏/灵动岛状态,issue #23 P2)。
@main
struct RecordingWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
    }
}

/// 录音 Live Activity:锁屏横幅 + 灵动岛(展开 / 紧凑 / 最小)。计时用 `Text(timerInterval:)` 自走,
/// 不依赖 app 后台推送更新。展示型(无交互按钮)——用户解锁后回 app 上滑停止。
struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // 锁屏 / 横幅
            HStack(spacing: 12) {
                pulse
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在录音").font(.subheadline).bold().foregroundStyle(.white)
                    Text(subtitle(context)).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                timer(context).font(.system(.title3, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("录音", systemImage: "mic.fill").foregroundStyle(.red).font(.caption).bold()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context).monospacedDigit().foregroundStyle(.white).font(.system(.body, design: .rounded))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(subtitle(context) + " · 解锁后上滑停止").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                timer(context).monospacedDigit().foregroundStyle(.white).frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }

    private var pulse: some View {
        Circle().fill(.red).frame(width: 10, height: 10)
    }

    private func timer(_ c: ActivityViewContext<RecordingActivityAttributes>) -> Text {
        Text(timerInterval: c.state.startedAt...Date.distantFuture, countsDown: false)
    }

    private func subtitle(_ c: ActivityViewContext<RecordingActivityAttributes>) -> String {
        c.state.projectName.map { "Agent Deck → \($0)" } ?? "Agent Deck"
    }
}
