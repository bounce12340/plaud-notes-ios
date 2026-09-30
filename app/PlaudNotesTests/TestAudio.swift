import AVFoundation
import Foundation

enum TestAudio {
    /// 寫出 0.2 秒靜音的 AAC M4A，並在 metadata 設定 creationDate。
    static func writeSilentM4A(to url: URL, creationDate: Date) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let dateItem = AVMutableMetadataItem()
        dateItem.identifier = .quickTimeMetadataCreationDate
        dateItem.value = ISO8601DateFormatter().string(from: creationDate) as NSString
        writer.metadata = [dateItem]

        let sampleRate = 44_100.0
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frames = 8_820
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                 formatDescriptionOut: &format))
        var block: CMBlockBuffer?
        let bytes = frames * 2
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                     blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: bytes, flags: 0, blockBufferOut: &block))
        try check(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes))
        var sample: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample))

        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        input.append(sample!)
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
