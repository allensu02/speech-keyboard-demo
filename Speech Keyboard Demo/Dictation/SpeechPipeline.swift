import AVFAudio
import CoreMedia
import Foundation
import Speech

nonisolated struct SpeechUpdate: Sendable {
    let epoch: UUID
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
}

actor SpeechPipeline {
    private var epoch: UUID?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var acceptingAfter: TimeInterval = .infinity
    private var sampleOffset: Int64 = 0

    nonisolated static func prepare(progress: @escaping @MainActor @Sendable (Double?) -> Void) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw DictationError.unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw DictationError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        _ = try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let monitor = Task {
                while !Task.isCancelled {
                    await progress(installation.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { monitor.cancel() }
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        await progress(nil)
        return locale
    }

    func begin(epoch newEpoch: UUID, locale: Locale,
               onUpdate: @escaping @Sendable (SpeechUpdate) async -> Void,
               onFailure: @escaping @Sendable (UUID) async -> Void) async throws {
        await cancel()
        try Task.checkCancellation()
        epoch = newEpoch
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.audioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard epoch == newEpoch else { throw CancellationError() }
        self.format = format
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
        input = pair.continuation
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    await onUpdate(SpeechUpdate(epoch: newEpoch, start: result.range.start.seconds,
                                                end: CMTimeRangeGetEnd(result.range).seconds,
                                                text: String(result.text.characters), isFinal: result.isFinal))
                }
            } catch {
                if !Task.isCancelled { await onFailure(newEpoch) }
            }
        }
        try await analyzer.start(inputSequence: pair.stream)
        guard epoch == newEpoch else { throw CancellationError() }
        acceptingAfter = ProcessInfo.processInfo.systemUptime
    }

    func consume(_ frame: CapturedAudio) throws {
        guard frame.capturedAt >= acceptingAfter, let format, let input else { return }
        if sourceFormat != frame.buffer.format {
            converter = AVAudioConverter(from: frame.buffer.format, to: format)
            sourceFormat = frame.buffer.format
        }
        guard let converter else { throw DictationError.audioFormat }
        let ratio = format.sampleRate / frame.buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frame.buffer.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw DictationError.audioFormat }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return frame.buffer
        }
        guard status != .error, conversionError == nil else { throw DictationError.audioFormat }
        guard output.frameLength > 0 else { return }
        let timestamp = CMTime(value: sampleOffset, timescale: CMTimeScale(format.sampleRate))
        sampleOffset += Int64(output.frameLength)
        if case .dropped = input.yield(AnalyzerInput(buffer: output, bufferStartTime: timestamp)) {
            throw DictationError.audioOverflow
        }
    }

    func finish() async {
        acceptingAfter = .infinity
        input?.finish()
        input = nil
        guard let analyzer else { return }
        // Cancellation of finalization alone may not unblock the framework; explicitly cancel it.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await analyzer.cancelAndFinishNow()
        }
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultTask?.value
        timeout.cancel()
        await cancel()
    }

    func cancel() async {
        acceptingAfter = .infinity
        epoch = nil
        input?.finish()
        input = nil
        resultTask?.cancel()
        resultTask = nil
        let previous = analyzer
        analyzer = nil
        format = nil
        converter = nil
        sourceFormat = nil
        sampleOffset = 0
        await previous?.cancelAndFinishNow()
    }
}
