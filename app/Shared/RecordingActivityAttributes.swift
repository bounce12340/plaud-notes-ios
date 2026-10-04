import ActivityKit
import Foundation

/// 錄音的即時動態（鎖定畫面與動態島）。App 與 Widget Extension 共用。
struct RecordingActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable, Sendable {
        case recording, paused, interrupted
    }

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        /// 錄音中時計時的起點（現在減去已錄時間）；畫面用 Text(timerInterval:) 自己走秒，不必每秒更新
        var timerStart: Date
        /// 暫停或中斷時顯示的固定時間
        var elapsed: TimeInterval

        init(phase: Phase, elapsed: TimeInterval, now: Date = .now) {
            self.phase = phase
            self.elapsed = elapsed
            timerStart = now.addingTimeInterval(-elapsed)
        }

        var label: String {
            switch phase {
            case .recording: "錄音中"
            case .paused: "已暫停"
            case .interrupted: "中斷中，結束後自動繼續"
            }
        }
    }

    var startedAt: Date
}
