import SwiftUI
import UIKit

@main
struct PlaudNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var library: RecordingLibrary
    @State private var settings: AppSettings
    @State private var templates: TemplateStore
    @State private var glossary: GlossaryStore
    @State private var transcription: TranscriptionCoordinator

    init() {
        let library = RecordingLibrary()
        let settings = AppSettings()
        let glossary = GlossaryStore()
        _library = State(initialValue: library)
        _settings = State(initialValue: settings)
        _templates = State(initialValue: TemplateStore())
        _glossary = State(initialValue: glossary)
        // App 被系統喚醒接收背景轉錄結果時也會走到這裡；BackgroundTranscriber.shared 會重新連上背景 session
        _transcription = State(initialValue: TranscriptionCoordinator(
            transcriber: .shared, library: library, settings: settings, glossary: glossary))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(settings)
                .environment(templates)
                .environment(glossary)
                .environment(transcription)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // 在鎖定時被背景喚醒的話，資料檔當時讀不到，回到前景再讀一次
            library.reloadIfNeeded()
            templates.reloadIfNeeded()
            glossary.reloadIfNeeded()
            Task { await transcription.processPending() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 背景上傳完成時系統喚醒 App；所有事件送完後要呼叫 completionHandler
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTranscriber.sessionIdentifier else { return completionHandler() }
        nonisolated(unsafe) let completion = completionHandler
        BackgroundTranscriber.shared.setBackgroundCompletion { @MainActor in completion() }
    }
}
