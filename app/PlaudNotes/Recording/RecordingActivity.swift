import ActivityKit
import Foundation

/// 管理錄音的即時動態。使用者在「設定」關閉即時動態時什麼都不做。
@MainActor
enum RecordingActivity {
    private static var current: Activity<RecordingActivityAttributes>?

    static func start(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let state = RecordingActivityAttributes.ContentState(phase: .recording, elapsed: 0)
        current = try? Activity.request(attributes: RecordingActivityAttributes(startedAt: startedAt),
                                        content: ActivityContent(state: state, staleDate: nil))
    }

    static func update(_ phase: RecordingActivityAttributes.Phase, elapsed: TimeInterval) {
        guard let activity = current else { return }
        let state = RecordingActivityAttributes.ContentState(phase: phase, elapsed: elapsed)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    static func end() {
        guard let activity = current else { return }
        current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// App 上次錄音中被終止時，留下的即時動態會一直停在畫面上；啟動時結束掉
    static func endStale(keeping active: Bool) {
        guard !active else { return }
        for activity in Activity<RecordingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
