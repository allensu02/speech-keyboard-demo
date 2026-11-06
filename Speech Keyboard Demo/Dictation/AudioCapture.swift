import AVFAudio
import Foundation

/// A private buffer copy, transferred once from the render callback to the speech actor.
nonisolated struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let capturedAt: TimeInterval
}

@MainActor final class AudioCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation?
    private var tapInstalled = false

    func start() throws -> AsyncThrowingStream<CapturedAudio, Error> {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false)
            throw DictationError.audioFormat
        }
        let pair = AsyncThrowingStream<CapturedAudio, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        continuation = pair.continuation
        let sink = pair.continuation
        // Explicitly nonisolated: AVAudioEngine invokes this on its render thread.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            let capturedAt = ProcessInfo.processInfo.systemUptime
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                sink.finish(throwing: DictationError.audioOverflow)
                return
            }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (sourceBuffer, destinationBuffer) in zip(source, destination) {
                if let from = sourceBuffer.mData, let to = destinationBuffer.mData {
                    memcpy(to, from, Int(sourceBuffer.mDataByteSize))
                }
            }
            if case .dropped = sink.yield(CapturedAudio(buffer: copy, capturedAt: capturedAt)) {
                sink.finish(throwing: DictationError.audioOverflow)
            }
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
        return pair.stream
    }

    func stop() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
