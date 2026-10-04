import Foundation
import Synchronization
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PlaudNotes

/// 長音檔上傳：請求本文從暫存檔串流、重送規則、進度回報。不連網，用 MockHTTP 回應。
final class UploadTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        MockHTTP.reset()
    }

    private func tempFile(_ data: Data, ext: String = "bin") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "upload-test-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        tempFiles.append(url)
        return url
    }

    // MARK: - multipart 本文寫到檔案

    func testMultipartBodyStreamsFileInChunks() throws {
        let audio = Data((0..<10_000).map { UInt8($0 % 251) })
        let src = try tempFile(audio, ext: "mp3")
        let dst = FileManager.default.temporaryDirectory.appending(path: "mp-\(UUID().uuidString).multipart")
        tempFiles.append(dst)

        let size = try Multipart.writeBody(to: dst, boundary: "B", fields: [("keyterms", "A"), ("keyterms", "B")],
                                           fileField: "file", fileURL: src, chunkSize: 4096)
        let body = try Data(contentsOf: dst)
        XCTAssertEqual(Int64(body.count), size)
        let head = Data("--B\r\nContent-Disposition: form-data; name=\"keyterms\"\r\n\r\nA\r\n".utf8)
        XCTAssertEqual(body.prefix(head.count), head)
        XCTAssertNotNil(body.range(of: Data("filename=\"\(src.lastPathComponent)\"".utf8)))
        XCTAssertNotNil(body.range(of: audio), "音檔內容要完整、連續（跨 4096 bytes 的分塊）")
        XCTAssertEqual(body.suffix(9), Data("\r\n--B--\r\n".utf8))
    }

    // MARK: - 重送規則

    func testRetryOnlyWhenServerDidNotProcess() {
        XCTAssertTrue(UploadRetry.shouldRetry(ProviderError.http(429, ""), bodyFullySent: true))
        XCTAssertTrue(UploadRetry.shouldRetry(ProviderError.http(503, ""), bodyFullySent: true))
        XCTAssertFalse(UploadRetry.shouldRetry(ProviderError.http(500, ""), bodyFullySent: true))
        XCTAssertFalse(UploadRetry.shouldRetry(ProviderError.http(401, ""), bodyFullySent: true))
        XCTAssertFalse(UploadRetry.shouldRetry(ProviderError.http(400, ""), bodyFullySent: false))
        // 音檔沒送完就斷線：可重送
        XCTAssertTrue(UploadRetry.shouldRetry(URLError(.networkConnectionLost), bodyFullySent: false))
        XCTAssertTrue(UploadRetry.shouldRetry(URLError(.timedOut), bodyFullySent: false))
        // 送完才斷線：伺服器可能已處理並計費，不重送
        XCTAssertFalse(UploadRetry.shouldRetry(URLError(.networkConnectionLost), bodyFullySent: true))
        XCTAssertFalse(UploadRetry.shouldRetry(URLError(.cancelled), bodyFullySent: false))
        XCTAssertFalse(UploadRetry.shouldRetry(CancellationError(), bodyFullySent: false))
    }

    func testFinalErrorExplainsPossibleCharge() {
        let e = UploadRetry.finalError(URLError(.networkConnectionLost), bodyFullySent: true)
        guard case ProviderError.interruptedAfterUpload = e else { return XCTFail("\(e)") }
        XCTAssertTrue(e.localizedDescription.contains("可能已處理並計費"))
        XCTAssertTrue(UploadRetry.finalError(URLError(.networkConnectionLost), bodyFullySent: false) is URLError)
        XCTAssertTrue(UploadRetry.finalError(URLError(.cancelled), bodyFullySent: true) is URLError)
    }

    // MARK: - 進度

    @MainActor
    func testObserverReportsMonotonicProgressThenProcessing() async {
        let log = ProgressLog()
        let observer = UploadObserver(onProgress: { log.append($0) })
        observer.record(sent: 0, total: 1000)
        observer.record(sent: 5, total: 1000)       // 仍是 0%：不重複回報
        observer.record(sent: 500, total: 1000)
        observer.record(sent: 400, total: 1000)     // 倒退：忽略
        XCTAssertFalse(observer.bodyFullySent)
        observer.record(sent: 1000, total: 1000)
        observer.record(sent: 1000, total: 1000)    // 重複的最後一次：忽略
        await observer.finish()
        XCTAssertTrue(observer.bodyFullySent)
        XCTAssertEqual(log.items, [.uploading(0), .uploading(0.5), .uploading(1), .processing])
    }

    func testProgressLabels() {
        XCTAssertEqual(TranscriptionProgress.uploading(0.456).label, "上傳中（45%）…")
        XCTAssertEqual(TranscriptionProgress.compacting(1).label, "壓縮音檔中（100%）…")
        XCTAssertEqual(TranscriptionProgress.retrying(attempt: 2, of: 3).label, "暫時失敗，重試中（第 2/3 次）…")
    }

    // MARK: - 整個轉錄請求（MockHTTP）

    private static let okJSON = #"{"language_code":"zho","text":"你好","words":[{"text":"你好","start":0.1,"end":0.5,"type":"word","speaker_id":"speaker_0"}]}"#

    private func provider() -> ElevenLabsProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        var p = ElevenLabsProvider(apiKey: "test-key", session: URLSession(configuration: config))
        p.retryDelay = { _ in .milliseconds(1) }
        return p
    }

    @MainActor
    func testRetriesServiceUnavailableThenSucceeds() async throws {
        MockHTTP.enqueue(.status(503, "busy"), .status(200, Self.okJSON))
        let log = ProgressLog()
        let t = try await provider().transcribe(fileURL: tempFile(Data(repeating: 7, count: 2048), ext: "mp3"),
                                                options: TranscriptionOptions(keyterms: ["Plaud"]),
                                                onProgress: { log.append($0) })
        XCTAssertEqual(t.plainText, "你好")
        XCTAssertEqual(MockHTTP.requestCount, 2)
        XCTAssertTrue(log.items.contains(.retrying(attempt: 2, of: 3)))
        let req = try XCTUnwrap(MockHTTP.lastRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "test-key")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        if let body = MockHTTP.lastBody {
            XCTAssertNotNil(body.range(of: Data("name=\"keyterms\"\r\n\r\nPlaud".utf8)))
            XCTAssertNotNil(body.range(of: Data(repeating: 7, count: 2048)))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("elevenlabs-") && $0.hasSuffix(".multipart") }.isEmpty, "暫存的請求本文要刪除")
    }

    func testRetriesNetworkLossBeforeUpload() async throws {
        MockHTTP.enqueue(.failure(URLError(.networkConnectionLost)), .status(200, Self.okJSON))
        let t = try await provider().transcribe(fileURL: tempFile(Data([1, 2, 3]), ext: "mp3"),
                                                options: TranscriptionOptions())
        XCTAssertEqual(t.segments.first?.speaker, "speaker_0")
        XCTAssertEqual(MockHTTP.requestCount, 2)
    }

    func testDoesNotRetryAuthErrorAndGivesUpAfterThreeAttempts() async throws {
        let file = try tempFile(Data([1]), ext: "mp3")
        MockHTTP.enqueue(.status(401, "invalid api key"))
        do {
            _ = try await provider().transcribe(fileURL: file, options: TranscriptionOptions())
            XCTFail("應該失敗")
        } catch ProviderError.http(let code, let msg) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(msg.contains("invalid"))
        }
        XCTAssertEqual(MockHTTP.requestCount, 1)

        MockHTTP.reset()
        MockHTTP.enqueue(.status(429, "a"), .status(429, "b"), .status(429, "c"), .status(200, Self.okJSON))
        do {
            _ = try await provider().transcribe(fileURL: file, options: TranscriptionOptions())
            XCTFail("應該失敗")
        } catch ProviderError.http(let code, let msg) {
            XCTAssertEqual(code, 429)
            XCTAssertEqual(msg, "c")
        }
        XCTAssertEqual(MockHTTP.requestCount, UploadRetry.maxAttempts)
    }
}

@MainActor
private final class ProgressLog {
    var items: [TranscriptionProgress] = []
    func append(_ p: TranscriptionProgress) { items.append(p) }
}

/// 依序回應預先排好的結果，並記錄收到的請求。
final class MockHTTP: URLProtocol {
    enum Reply: Sendable {
        case status(Int, String)
        case failure(URLError)
    }

    private struct State {
        var replies: [Reply] = []
        var count = 0
        var lastRequest: URLRequest?
        var lastBody: Data?
    }
    private static let state = Mutex(State())

    static func enqueue(_ replies: Reply...) { state.withLock { $0.replies += replies } }
    static func reset() { state.withLock { $0 = State() } }
    static var requestCount: Int { state.withLock { $0.count } }
    static var lastRequest: URLRequest? { state.withLock { $0.lastRequest } }
    /// 平台有提供上傳本文串流時才有值
    static var lastBody: Data? { state.withLock { $0.lastBody } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let reply = Self.state.withLock { s -> Reply in
            s.count += 1
            s.lastRequest = request
            s.lastBody = body
            return s.replies.isEmpty ? .status(500, "no reply queued") : s.replies.removeFirst()
        }
        switch reply {
        case .status(let code, let text):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
