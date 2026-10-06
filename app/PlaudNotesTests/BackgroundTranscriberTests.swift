import Foundation
import Synchronization
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PlaudNotes

/// 背景轉錄的 delegate 流程與暫存資料。用一般 session＋MockHTTP 跑同一套 delegate 程式碼；
/// 真正的背景 session 由 LiveTranscriptionTests 實測。
final class BackgroundTranscriberTests: XCTestCase {
    private var root: URL!
    private var transcriber: BackgroundTranscriber?

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appending(path: "jobs-\(UUID().uuidString)")
        MockHTTP.reset()
    }

    override func tearDown() {
        transcriber?.invalidate()
        try? FileManager.default.removeItem(at: root)
        MockHTTP.reset()
    }

    private static let okJSON = #"{"language_code":"zho","text":"你好","words":[{"text":"你好","start":0.1,"end":0.5,"type":"word","speaker_id":"speaker_0"}]}"#

    private func make() -> (BackgroundTranscriber, TranscriberEventLog) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        let t = BackgroundTranscriber(configuration: config, store: TranscriptionJobStore(root: root),
                                      retryDelay: { _ in 0 })
        let log = TranscriberEventLog()
        t.setEventHandler { log.append($0) }
        transcriber = t
        return (t, log)
    }

    private func audio() throws -> URL {
        let url = root.appending(path: "audio.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 4096).write(to: url)
        return url
    }

    func testSuccessStoresResponseAndRemovesBody() async throws {
        let (t, log) = make()
        MockHTTP.enqueue(.status(200, Self.okJSON))
        let id = UUID()
        try await t.start(recordingID: id, audioURL: audio(), provider: ElevenLabsProvider(apiKey: "k"),
                          options: TranscriptionOptions(keyterms: ["Plaud"]))
        let last = try await log.waitForFinal(id)
        XCTAssertEqual(last, .finished(id))
        XCTAssertEqual(t.store.job(id)?.status, .finished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.store.bodyURL(id).path), "上傳本文要刪除")
        let raw = try ElevenLabsProvider.parse(Data(contentsOf: t.store.responseURL(id)))
        XCTAssertEqual(raw.plainText, "你好")
        XCTAssertEqual(MockHTTP.lastRequest?.value(forHTTPHeaderField: "xi-api-key"), "k")
    }

    func testRetriesServiceUnavailableThenSucceeds() async throws {
        let (t, log) = make()
        MockHTTP.enqueue(.status(503, "busy"), .status(200, Self.okJSON))
        let id = UUID()
        try await t.start(recordingID: id, audioURL: audio(), provider: ElevenLabsProvider(apiKey: "k"),
                          options: TranscriptionOptions())
        let last = try await log.waitForFinal(id)
        XCTAssertEqual(last, .finished(id))
        XCTAssertEqual(MockHTTP.requestCount, 2)
        XCTAssertEqual(t.store.job(id)?.attempt, 2)
        XCTAssertTrue(log.events.contains(.progress(id, .retrying(attempt: 2, of: 3))))
    }

    func testAuthErrorFailsWithoutRetry() async throws {
        let (t, log) = make()
        MockHTTP.enqueue(.status(401, "invalid api key"))
        let id = UUID()
        try await t.start(recordingID: id, audioURL: audio(), provider: ElevenLabsProvider(apiKey: "k"),
                          options: TranscriptionOptions())
        guard case .failed(id, let message) = try await log.waitForFinal(id) else { return XCTFail() }
        XCTAssertTrue(message.contains("401"), message)
        XCTAssertEqual(MockHTTP.requestCount, 1)
        XCTAssertEqual(t.store.job(id)?.status, .failed(message))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.store.bodyURL(id).path))
    }

    func testCancelRemovesJobWithoutFailure() async throws {
        let (t, log) = make()
        let id = UUID()
        MockHTTP.enqueue(.status(200, Self.okJSON))
        try await t.start(recordingID: id, audioURL: audio(), provider: ElevenLabsProvider(apiKey: "k"),
                          options: TranscriptionOptions())
        await t.cancel(recordingID: id)
        XCTAssertNil(t.store.job(id))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(log.events.contains { if case .failed = $0 { true } else { false } })
    }

    func testReconcileMarksOrphanedUploadAsFailed() async throws {
        let (t, log) = make()
        let id = UUID()
        try t.store.prepare(id)
        try t.store.save(TranscriptionJob(recordingID: id, attempt: 1, status: .uploading, startedAt: .now))
        await t.reconcile()
        guard case .failed(id, _) = try await log.waitForFinal(id) else { return XCTFail() }
        guard case .failed = t.store.job(id)?.status else { return XCTFail() }
    }

    func testStoreListsJobsAndRemoves() throws {
        let store = TranscriptionJobStore(root: root)
        let a = UUID(), b = UUID()
        for (id, offset) in [(a, 0.0), (b, 10.0)] {
            try store.prepare(id)
            try store.save(TranscriptionJob(recordingID: id, attempt: 1, status: .uploading,
                                            startedAt: Date(timeIntervalSince1970: offset)))
        }
        XCTAssertEqual(store.allJobs().map(\.recordingID), [a, b])
        try store.saveResponse(Data("{}".utf8), for: a)
        XCTAssertEqual(store.job(a)?.status, .finished)
        store.remove(a)
        XCTAssertEqual(store.allJobs().map(\.recordingID), [b])
    }

    func testOutcome() {
        let url = URL(string: "https://example.com")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        let bad = HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)
        guard case .success = BackgroundTranscriber.outcome(error: nil, response: ok, data: Data()) else { return XCTFail() }
        guard case .failure(ProviderError.http(422, "x")) = BackgroundTranscriber.outcome(error: nil, response: bad, data: Data("x".utf8)) else { return XCTFail() }
        guard case .failure(ProviderError.badResponse) = BackgroundTranscriber.outcome(error: nil, response: nil, data: Data()) else { return XCTFail() }
    }

    func testPipelineKeepsSpeakerNamesAndAppliesGlossaryAfterConversion() {
        let raw = Transcript(languageCode: "zho", segments: [.init(start: 0, end: 1, speaker: "speaker_0", text: "骨松药物")],
                             engine: "elevenlabs")
        let entries = Glossary.parse("骨松, 骨鬆 => 骨質疏鬆")
        let t = TranscriptPipeline.process(raw, entries: entries, converter: nil, speakerNames: ["speaker_0": "王經理"])
        XCTAssertEqual(t.speakerNames?["speaker_0"], "王經理")
        XCTAssertEqual(t.segments.first?.text, "骨質疏鬆药物", "沒有轉換器時只套詞庫")
    }
}

struct TranscriberTimeout: Error { let events: [BackgroundTranscriber.Event] }

/// 收集事件，並能等某段錄音的最後結果（完成或失敗）
final class TranscriberEventLog: Sendable {
    private let state = Mutex<[BackgroundTranscriber.Event]>([])
    var events: [BackgroundTranscriber.Event] { state.withLock { $0 } }
    func append(_ e: BackgroundTranscriber.Event) { state.withLock { $0.append(e) } }

    func waitForFinal(_ id: UUID, timeout: Duration = .seconds(10)) async throws -> BackgroundTranscriber.Event {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let e = events.last(where: { e in
                switch e {
                case .finished(let x), .failed(let x, _): x == id
                case .progress: false
                }
            }) { return e }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TranscriberTimeout(events: events)
    }
}
