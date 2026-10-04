import AVFoundation
import Foundation

/// 上傳轉錄前，把高位元率的大檔轉成 16 kHz 單聲道 AAC，縮短上傳時間。
///
/// - 只壓縮「位元率高於 96 kbps 且大於 20 MB」的檔案，例如語音備忘錄的高品質 M4A、WAV。
///   樣本 A（語音備忘錄）約 133 kbps；App 自己的錄音是 64 kbps、Plaud MP3 是 32 kbps，都原檔上傳，
///   不再做一次有損轉檔。
/// - 時間軸不變，逐字稿的時間戳仍對得上原始音檔。
/// - 壓縮失敗就改傳原檔，不讓轉錄因此失敗。
enum AudioCompactor {
    static let minimumBitRate = 96_000.0
    static let minimumBytes: Int64 = 20 * 1024 * 1024
    static let sampleRate = 16_000.0
    /// 依序嘗試，取編碼器接受的第一個
    static let candidateBitRates = [48_000, 32_000, 24_000]

    static func shouldCompact(fileSize: Int64, duration: Double) -> Bool {
        guard fileSize > minimumBytes, duration > 0 else { return false }
        return Double(fileSize) * 8 / duration > minimumBitRate
    }

    /// 需要壓縮就回傳暫存檔（呼叫端用完要刪除）；不需要或壓縮失敗回傳 nil，改傳原檔。
    static func compactIfNeeded(_ url: URL,
                                onProgress: (@MainActor @Sendable (Double) -> Void)? = nil) async -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let duration = try? await AVURLAsset(url: url).load(.duration).seconds,
              shouldCompact(fileSize: Int64(size), duration: duration) else { return nil }
        let out = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).m4a")
        do {
            try await compact(url, to: out, duration: duration, onProgress: onProgress)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
    }

    /// 解碼成 16 kHz 單聲道 PCM，再編成 AAC。回傳使用的位元率。
    @discardableResult
    static func compact(_ source: URL, to destination: URL, duration: Double,
                        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> Int {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CompactError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CompactError.cannotRead }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let base: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        guard let bitRate = candidateBitRates.first(where: {
            writer.canApply(outputSettings: base.merging([AVEncoderBitRateKey: $0]) { $1 }, forMediaType: .audio)
        }) else { throw CompactError.unsupportedSettings }
        let input = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: base.merging([AVEncoderBitRateKey: bitRate]) { $1 })
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? CompactError.cannotRead }
        guard writer.startWriting() else { throw writer.error ?? CompactError.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        var lastPercent = -1
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading(); writer.cancelWriting()
                throw CancellationError()
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard input.append(buffer) else { throw writer.error ?? CompactError.cannotWrite }
            if duration > 0, let onProgress {
                let percent = Int(buffer.presentationTimeStamp.seconds / duration * 100)
                if percent > lastPercent {
                    lastPercent = percent
                    await onProgress(min(1, Double(percent) / 100))
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? CompactError.cannotRead }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompactError.cannotWrite }
        return bitRate
    }

    enum CompactError: LocalizedError {
        case noAudioTrack, cannotRead, cannotWrite, unsupportedSettings

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "檔案沒有音軌"
            case .cannotRead: "無法讀取音檔"
            case .cannotWrite: "無法寫出壓縮檔"
            case .unsupportedSettings: "編碼器不支援 16 kHz 單聲道 AAC 設定"
            }
        }
    }
}
