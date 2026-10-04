import AVFoundation
import XCTest
@testable import PlaudNotes

/// 用錄音的同一組設定（AAC 48 kHz 單聲道 64 kbps、.aac）在 iOS 上寫檔，確認：
/// 1. 寫出來的是 ADTS（逐格可讀）；2. 還沒關檔時複製出來的「閃退」檔可以救回並由 AVFoundation 讀取。
/// 模擬器沒有麥克風權限，所以用 AVAudioFile 寫入合成音，而不是 AVAudioRecorder。
final class RecorderFileTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "recfile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func toneBuffer(_ format: AVAudioFormat, second: Int) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        let freq = 300.0 + Double(second % 5) * 50
        for i in 0..<Int(frames) { data[i] = Float(0.3 * sin(2 * .pi * freq * Double(i) / format.sampleRate)) }
        return buffer
    }

    func testRecordingFormatIsADTSAndRecoverableBeforeClose() throws {
        let url = dir.appending(path: "rec.aac")
        let crashCopy = dir.appending(path: "crash.aac")
        do {
            let file = try AVAudioFile(forWriting: url, settings: Recorder.settings)
            for s in 0..<20 {
                try file.write(from: toneBuffer(file.processingFormat, second: s))
                // 寫到一半「閃退」：直接複製目前磁碟上的內容
                if s == 14 { try FileManager.default.copyItem(at: url, to: crashCopy) }
            }
            file.close()
        }

        let full = try ADTS.scan(url)
        print("COMPACT adts full frames=\(full.frames) duration=\(full.duration)")
        XCTAssertEqual(full.sampleRate, 48_000)
        XCTAssertEqual(full.duration, 20, accuracy: 0.2, "正常關檔的長度")

        let crashed = try ADTS.scan(crashCopy)
        print("COMPACT adts crash-copy frames=\(crashed.frames) duration=\(crashed.duration)")
        XCTAssertGreaterThan(crashed.duration, 10, "關檔前已寫入大部分內容")
        XCTAssertLessThanOrEqual(crashed.duration, 15.1)

        // 救回流程：切掉不完整的尾巴後，AVFoundation 要能讀
        var session = RecordingSession(id: UUID(), startedAt: .now)
        session.parts = [session.fileName]
        try FileManager.default.moveItem(at: crashCopy, to: dir.appending(path: session.fileName))
        let result = try XCTUnwrap(RecordingSessionStore.finalize(session, in: dir))
        let recovered = try AVAudioFile(forReading: dir.appending(path: result.fileName))
        let seconds = Double(recovered.length) / recovered.fileFormat.sampleRate
        print("COMPACT adts recovered avfoundation=\(seconds)s scan=\(result.duration)s")
        XCTAssertEqual(seconds, result.duration, accuracy: 0.2)
    }

    func testPartsJoinIntoOneReadableFile() throws {
        var session = RecordingSession(id: UUID(), startedAt: .now)
        for _ in 0..<2 {
            let name = session.nextPartName()
            session.parts.append(name)
            let file = try AVAudioFile(forWriting: dir.appending(path: name), settings: Recorder.settings)
            for s in 0..<5 { try file.write(from: toneBuffer(file.processingFormat, second: s)) }
            file.close()
        }
        let result = try XCTUnwrap(RecordingSessionStore.finalize(session, in: dir))
        XCTAssertEqual(result.duration, 10, accuracy: 0.2)
        let joined = try AVAudioFile(forReading: dir.appending(path: result.fileName))
        XCTAssertEqual(Double(joined.length) / joined.fileFormat.sampleRate, 10, accuracy: 0.2)
    }
}
