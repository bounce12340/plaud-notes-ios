import AVFoundation
import XCTest
@testable import PlaudNotes

/// 上傳前壓縮：高位元率大檔 → 16 kHz 單聲道 AAC，時間軸不變。
final class AudioCompactorTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
    }

    private func tempURL(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "compact-\(UUID().uuidString).\(ext)")
        tempFiles.append(url)
        return url
    }

    /// 寫出 44.1 kHz 立體聲 16-bit WAV（約 1411 kbps），內容是會變化的音調
    private func writeWAV(seconds: Int) throws -> URL {
        let url = tempURL("wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for s in 0..<seconds {
            let freq = 220.0 + Double(s % 10) * 40
            for ch in 0..<Int(format.channelCount) {
                let data = try XCTUnwrap(buffer.floatChannelData?[ch])
                for i in 0..<Int(frames) {
                    data[i] = Float(0.3 * sin(2 * .pi * freq * Double(i) / format.sampleRate))
                }
            }
            try file.write(from: buffer)
        }
        file.close()
        return url
    }

    func testShouldCompactThresholds() {
        let mb: Int64 = 1024 * 1024
        // 語音備忘錄（樣本 A：24 分鐘 24.4 MB，約 133 kbps）
        XCTAssertTrue(AudioCompactor.shouldCompact(fileSize: 24 * mb + 400_000, duration: 24 * 60 + 13))
        // App 錄音 64 kbps、3 小時約 86 MB：不壓縮
        XCTAssertFalse(AudioCompactor.shouldCompact(fileSize: 86 * mb, duration: 3 * 3600))
        // Plaud MP3 32 kbps：不壓縮
        XCTAssertFalse(AudioCompactor.shouldCompact(fileSize: 43 * mb, duration: 3 * 3600))
        // 小檔即使位元率高也不壓縮
        XCTAssertFalse(AudioCompactor.shouldCompact(fileSize: 10 * mb, duration: 60))
        XCTAssertFalse(AudioCompactor.shouldCompact(fileSize: 100 * mb, duration: 0))
    }

    func testCompactsWAVToSmall16kMonoAAC() async throws {
        let src = try writeWAV(seconds: 30)
        let dst = tempURL("m4a")
        let progress = ProgressRecorder()
        let bitRate = try await AudioCompactor.compact(src, to: dst, duration: 30) { progress.add($0) }

        let srcSize = try XCTUnwrap(src.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let dstSize = try XCTUnwrap(dst.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("COMPACT bitRate=\(bitRate) \(srcSize) → \(dstSize) bytes")
        XCTAssertTrue(AudioCompactor.candidateBitRates.contains(bitRate))
        XCTAssertLessThan(dstSize, srcSize / 20)

        let asset = AVURLAsset(url: dst)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 30, accuracy: 0.1, "時間軸要與原檔一致")
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let desc = try XCTUnwrap(descriptions.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee)
        XCTAssertEqual(asbd.mSampleRate, 16_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)

        let values = await progress.values
        XCTAssertEqual(values, values.sorted(), "進度只增不減")
        XCTAssertGreaterThanOrEqual(values.last ?? 0, 0.9)
    }

    func testCompactIfNeededSkipsSmallAndLowBitrateFiles() async throws {
        let wav = try writeWAV(seconds: 5)   // 高位元率但小於 20 MB
        let nilForWAV = await AudioCompactor.compactIfNeeded(wav)
        XCTAssertNil(nilForWAV)
        let mp3 = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plaud_sample", withExtension: "mp3"))
        let nilForMP3 = await AudioCompactor.compactIfNeeded(mp3)
        XCTAssertNil(nilForMP3)
    }
}

@MainActor
private final class ProgressRecorder {
    private(set) var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
}
