import Foundation
import Observation
import UIKit
import UserNotifications

/// 管理背景轉錄：開始、顯示進度、收到結果後整理成逐字稿。
///
/// 結果可能在螢幕鎖定時送達；逐字稿與錄音清單使用完整檔案保護，鎖定時無法讀寫，
/// 所以先把原始回應存在暫存區，等裝置解鎖（或 App 回到前景）再整理。
@MainActor
@Observable
final class TranscriptionCoordinator {
    private(set) var progress: [UUID: TranscriptionProgress] = [:]
    private(set) var failures: [UUID: String] = [:]
    /// 逐字稿被背景結果更新的次數；詳細頁看到變化就重新讀取
    private(set) var transcriptVersion: [UUID: Int] = [:]

    private let transcriber: BackgroundTranscriber
    private let library: RecordingLibrary
    private let settings: AppSettings
    private let glossary: GlossaryStore
    private var processing = false
    private var askedNotificationPermission = false

    init(transcriber: BackgroundTranscriber, library: RecordingLibrary, settings: AppSettings, glossary: GlossaryStore) {
        self.transcriber = transcriber
        self.library = library
        self.settings = settings
        self.glossary = glossary

        // 事件從 URLSession 的佇列送來；經由單一串流依序處理，進度不會因為 Task 先後而倒退
        let (stream, continuation) = AsyncStream<BackgroundTranscriber.Event>.makeStream()
        transcriber.setEventHandler { continuation.yield($0) }
        Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }

        for job in transcriber.store.allJobs() {
            switch job.status {
            case .uploading: progress[job.recordingID] = .background
            case .finished: progress[job.recordingID] = .processing
            case .failed(let message): failures[job.recordingID] = message
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.processPending() }
        }
        Task { [weak self] in
            // 稍等一下再檢查：App 剛啟動時，系統可能還在補送離線期間完成的工作
            try? await Task.sleep(for: .seconds(5))
            await self?.transcriber.reconcile()
            await self?.processPending()
        }
    }

    func isRunning(_ id: UUID) -> Bool { progress[id] != nil }

    /// 高位元率的大檔先壓縮（前景執行），再交給系統背景上傳。
    func start(item: RecordingItem, apiKey: String, options: TranscriptionOptions) async throws {
        let id = item.id
        failures[id] = nil
        progress[id] = .compacting(0)
        do {
            let source = library.url(for: item)
            let compacted = await AudioCompactor.compactIfNeeded(source) { [weak self] f in
                self?.progress[id] = .compacting(f)
            }
            defer { if let compacted { try? FileManager.default.removeItem(at: compacted) } }
            progress[id] = .uploading(0)
            try await transcriber.start(recordingID: id, audioURL: compacted ?? source,
                                        provider: ElevenLabsProvider(apiKey: apiKey), options: options)
        } catch {
            progress[id] = nil
            throw error
        }
        await requestNotificationPermissionOnce()
    }

    func cancel(_ id: UUID) async {
        await transcriber.cancel(recordingID: id)
        progress[id] = nil
    }

    func dismissFailure(_ id: UUID) {
        failures[id] = nil
        transcriber.store.remove(id)
    }

    // MARK: - 事件

    private func handle(_ event: BackgroundTranscriber.Event) {
        switch event {
        case .progress(let id, let p):
            progress[id] = p
            failures[id] = nil
        case .finished(let id):
            progress[id] = .processing
            failures[id] = nil
            notify(id, body: "轉錄完成，打開 App 查看逐字稿。")
            Task { await processPending() }
        case .failed(let id, let message):
            progress[id] = nil
            failures[id] = message
            notify(id, body: "轉錄失敗：\(message)")
        }
    }

    /// 把已完成的結果整理成逐字稿（需要裝置已解鎖）
    func processPending() async {
        guard !processing, UIApplication.shared.isProtectedDataAvailable else { return }
        processing = true
        defer { processing = false }
        library.reloadIfNeeded()
        glossary.reloadIfNeeded()
        // 清單沒讀到就不能判斷錄音是否已刪除
        guard !library.needsReload, !glossary.needsReload else { return }

        // 處理期間可能又有工作完成，處理到沒有新的為止；每筆只試一次，存檔失敗留到下次
        var attempted = Set<UUID>()
        while let job = transcriber.store.allJobs().first(where: {
            $0.status == .finished && !attempted.contains($0.recordingID)
        }) {
            let id = job.recordingID
            attempted.insert(id)
            guard let item = library.item(id: id) else {
                // 錄音已被刪除
                transcriber.store.remove(id)
                progress[id] = nil
                continue
            }
            do {
                let raw = try ElevenLabsProvider.parse(Data(contentsOf: transcriber.store.responseURL(id)))
                var converter: ChineseConverter?
                if let mode = settings.chineseConversion.mode {
                    converter = await ChineseConverterCache.shared.converter(mode)
                }
                let names = library.loadTranscript(for: item)?.speakerNames
                let entries = glossary.entries
                let conv = converter
                let transcript = await Task.detached(priority: .userInitiated) {
                    TranscriptPipeline.process(raw, entries: entries, converter: conv, speakerNames: names)
                }.value
                guard library.saveTranscript(transcript, for: item) else { continue }
                transcriber.store.remove(id)
                progress[id] = nil
                transcriptVersion[id, default: 0] += 1
            } catch {
                let message = "無法讀取轉錄結果：\(error.localizedDescription)"
                transcriber.store.markFailed(id, message: message)
                progress[id] = nil
                failures[id] = message
            }
        }
    }

    // MARK: - 通知（App 在背景時才發）

    private func requestNotificationPermissionOnce() async {
        guard !askedNotificationPermission else { return }
        askedNotificationPermission = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func notify(_ id: UUID, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = library.item(id: id)?.title ?? "Plaud Notes"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "transcription-\(id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
