import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PlaudNotesWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// 錄音中的鎖定畫面與動態島：錄音時間、狀態、停止按鈕。
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                PhaseIcon(phase: context.state.phase)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.label).font(.headline)
                    ElapsedText(state: context.state)
                        .font(.title3.monospacedDigit())
                }
                Spacer()
                StopButton()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.label, systemImage: "mic.fill")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StopButton()
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                ElapsedText(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 64)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }
}

private struct PhaseIcon: View {
    let phase: RecordingActivityAttributes.Phase

    var body: some View {
        switch phase {
        case .recording: Image(systemName: "mic.fill").foregroundStyle(.red)
        case .paused: Image(systemName: "pause.fill").foregroundStyle(.orange)
        case .interrupted: Image(systemName: "phone.fill").foregroundStyle(.orange)
        }
    }
}

private struct ElapsedText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
        } else {
            Text(Duration.seconds(state.elapsed), format: .time(pattern: .hourMinuteSecond))
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Label("停止", systemImage: "stop.fill")
        }
        .tint(.red)
    }
}
