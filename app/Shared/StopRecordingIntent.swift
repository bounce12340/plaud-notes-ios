import AppIntents
import Foundation

/// App 啟動時設定；即時動態上的「停止」按鈕會在 App 的程序裡執行它。
enum RecordingControl {
    @MainActor static var stop: (@MainActor @Sendable () -> Void)?
}

/// 鎖定畫面／動態島的停止按鈕。LiveActivityIntent 在 App 的程序執行（App 錄音中一定在執行）。
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "停止錄音"

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { RecordingControl.stop?() }
        return .result()
    }
}
