import ActivityKit
import Foundation

/// 管理錄音的即時動態。使用者在「設定」關閉即時動態時什麼都不做。
/// `Activity` 不是 Sendable：只記住 ID，更新與結束時在背景工作裡依 ID 取出，不跨執行緒傳遞。
@MainActor
enum RecordingActivity {
    private static var currentID: String?

    static func start(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let state = RecordingActivityAttributes.ContentState(phase: .recording, elapsed: 0)
        currentID = (try? Activity.request(attributes: RecordingActivityAttributes(startedAt: startedAt),
                                           content: ActivityContent(state: state, staleDate: nil)))?.id
    }

    static func update(_ phase: RecordingActivityAttributes.Phase, elapsed: TimeInterval) {
        guard let id = currentID else { return }
        let state = RecordingActivityAttributes.ContentState(phase: phase, elapsed: elapsed)
        Task.detached {
            for activity in Activity<RecordingActivityAttributes>.activities where activity.id == id {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    static func end() {
        guard let id = currentID else { return }
        currentID = nil
        Task.detached {
            for activity in Activity<RecordingActivityAttributes>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// App 上次錄音中被終止時，留下的即時動態會一直停在畫面上；啟動時結束掉
    static func endStale(keeping active: Bool) {
        guard !active else { return }
        Task.detached {
            for activity in Activity<RecordingActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
