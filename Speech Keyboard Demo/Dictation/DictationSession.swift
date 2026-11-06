import AVFAudio
import Foundation
import Observation
import OSLog
import UIKit

@MainActor @Observable final class DictationSession {
    private(set) var state: CaptureState = .idle
    private(set) var message = "Start here, then switch to a text field with Speech Keyboard."
    private(set) var downloadProgress: Double?
    private(set) var startedAt: Date?
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let speech = SpeechPipeline()
    @ObservationIgnored private var store: SharedSessionStore?
    @ObservationIgnored private var snapshot = SessionSnapshot(sessionID: UUID(), state: .idle)
    @ObservationIgnored private var buffer = TranscriptBuffer()
    @ObservationIgnored private var locale = Locale(identifier: "en-US")
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var epochTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.allensu.SpeechKeyboardDemo", category: "session")
    var canStart: Bool { state == .idle || state == .failed || state == .interrupted }

    init() {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let began = note.name == AVAudioSession.interruptionNotification &&
                    (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let routeChanged = note.name == AVAudioSession.routeChangeNotification &&
                    (reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
                let reset = note.name == AVAudioSession.mediaServicesWereResetNotification
                Task { @MainActor [weak self] in
                    guard let self, self.state.isCapturing, began || routeChanged || reset else { return }
                    self.fail("Listening was interrupted. Open Speech Keyboard and start again.", state: .interrupted)
                }
            })
        }
    }

    func start() {
        guard canStart else { return }
        snapshot = SessionSnapshot(sessionID: UUID(), state: .preparing)
        let sessionID = snapshot.sessionID
        state = .preparing
        message = "Preparing on-device speech recognition…"
        startupTask = Task {
            do {
                store = try SharedSessionStore()
                try store?.remove(.transcript)
                try store?.remove(.receiver)
                try publishStatus()
                guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphoneDenied }
                try Task.checkCancellation()
                locale = try await SpeechPipeline.prepare { [weak self] progress in
                    guard let self, self.snapshot.sessionID == sessionID, self.state == .preparing else { return }
                    self.downloadProgress = progress
                    if progress != nil { self.message = "Downloading the English speech model…" }
                }
                try Task.checkCancellation()
                guard snapshot.sessionID == sessionID else { return }
                let stream = try audio.start()
                startedAt = Date()
                state = .waitingForField
                message = "Listening is active. Select Speech Keyboard in a text field to begin dictating."
                downloadProgress = nil
                try publishStatus()
                audioTask = Task { [weak self, speech] in
                    do {
                        for try await frame in stream {
                            try Task.checkCancellation()
                            try await speech.consume(frame)
                        }
                    } catch {
                        guard !Task.isCancelled, let self, self.snapshot.sessionID == sessionID, self.state.isCapturing else { return }
                        self.fail((error as? DictationError)?.localizedDescription ?? "Audio input stopped. Start listening again.")
                    }
                }
                controlTask = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.tick()
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                    }
                }
            } catch {
                guard !Task.isCancelled, snapshot.sessionID == sessionID else { return }
                fail((error as? DictationError)?.localizedDescription ?? "Could not prepare listening. Check the connection and try again.")
            }
        }
    }

    func stop() async {
        guard !canStart, state != .stopping else { return }
        let sessionID = snapshot.sessionID
        state = .stopping
        message = "Finishing your last words…"
        startupTask?.cancel()
        epochTask?.cancel()
        controlTask?.cancel()
        audio.stop()
        audioTask?.cancel()
        try? publishStatus()
        await speech.finish()
        guard snapshot.sessionID == sessionID else { return }
        state = .idle
        message = "Listening stopped. Start again here whenever you’re ready."
        startedAt = nil
        downloadProgress = nil
        try? publishTranscript()
        try? publishStatus()
        logger.info("Capture stopped")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.snapshot.sessionID == sessionID, self.state == .idle else { return }
            try? self.store?.remove(.transcript)
            self.buffer = TranscriptBuffer()
        }
    }

    private func tick() {
        guard state.isCapturing, let store else { return }
        guard UIApplication.shared.isProtectedDataAvailable else { disconnectReceiver(); return }
        do {
            let receiver: ReceiverSnapshot? = try store.read(.receiver)
            if let receiver, receiver.schema == DictationBridge.schema, receiver.sessionID == snapshot.sessionID,
               let command = receiver.stopCommandID, command != snapshot.acknowledgedStopID {
                snapshot.acknowledgedStopID = command
                Task { await stop() }
                return
            }
            if let receiver, receiver.isValid(for: snapshot.sessionID) {
                if receiver.epoch != snapshot.epoch { connect(receiver) }
                else {
                    try buffer.acknowledge(through: receiver.lastFinalID)
                    try publishTranscript()
                }
            } else { disconnectReceiver() }
            try publishStatus()
        } catch DictationError.busy {
            // Retry on the next bounded polling tick.
        } catch {
            fail((error as? DictationError)?.localizedDescription ?? "The keyboard connection was interrupted. Start again.")
        }
    }

    private func connect(_ receiver: ReceiverSnapshot) {
        epochTask?.cancel()
        buffer = TranscriptBuffer()
        snapshot.epoch = receiver.epoch
        state = .connecting
        message = "Connecting to your text field…"
        let sessionID = snapshot.sessionID
        let epoch = receiver.epoch
        epochTask = Task { [weak self, speech, locale] in
            do {
                try await speech.begin(epoch: epoch, locale: locale, onUpdate: { [weak self] update in
                    await self?.receive(update, sessionID: sessionID)
                }, onFailure: { [weak self] failedEpoch in
                    await self?.speechFailed(epoch: failedEpoch, sessionID: sessionID)
                })
                try Task.checkCancellation()
                guard let self, self.snapshot.sessionID == sessionID, self.snapshot.epoch == epoch, self.state == .connecting else { return }
                self.state = .transcribing
                self.message = "Your words are appearing in the active text field."
                try self.publishStatus()
            } catch {
                guard !Task.isCancelled, let self, self.snapshot.epoch == epoch, self.snapshot.sessionID == sessionID else { return }
                self.fail((error as? DictationError)?.localizedDescription ?? "Speech recognition could not start. Try again.")
            }
        }
    }

    private func receive(_ update: SpeechUpdate, sessionID: UUID) {
        guard snapshot.sessionID == sessionID, snapshot.epoch == update.epoch, state == .transcribing || state == .stopping else { return }
        do {
            try buffer.receive(start: update.start, end: update.end, text: update.text, isFinal: update.isFinal)
            try publishTranscript()
        } catch DictationError.busy {
            // The buffer retains this update; the next tick republishes it.
        } catch {
            fail((error as? DictationError)?.localizedDescription ?? "Text delivery stopped. Start again.")
        }
    }

    private func speechFailed(epoch: UUID, sessionID: UUID) {
        guard snapshot.sessionID == sessionID, snapshot.epoch == epoch, state.isCapturing else { return }
        fail("Speech recognition was interrupted. Start listening again.")
    }

    private func disconnectReceiver() {
        guard snapshot.epoch != nil else { return }
        snapshot.epoch = nil
        epochTask?.cancel()
        Task { await speech.cancel() }
        buffer = TranscriptBuffer()
        state = .waitingForField
        message = "Listening is active. Waiting for Speech Keyboard."
        try? store?.remove(.transcript)
    }

    private func publishTranscript() throws {
        guard let epoch = snapshot.epoch else { return }
        try store?.write(TranscriptSnapshot(sessionID: snapshot.sessionID, epoch: epoch, revision: buffer.revision,
                                           finals: buffer.finals, provisional: buffer.provisional), to: .transcript)
    }

    private func publishStatus() throws {
        snapshot.state = state
        snapshot.heartbeat = .now
        snapshot.message = state == .failed || state == .interrupted ? message : nil
        try store?.write(snapshot, to: .session)
    }

    private func fail(_ reason: String, state failureState: CaptureState = .failed) {
        state = failureState
        message = reason
        snapshot.epoch = nil
        startupTask?.cancel()
        epochTask?.cancel()
        controlTask?.cancel()
        audioTask?.cancel()
        audio.stop()
        Task { await speech.cancel() }
        startedAt = nil
        downloadProgress = nil
        buffer = TranscriptBuffer()
        try? store?.remove(.transcript)
        try? publishStatus()
        logger.error("Capture ended with a recoverable failure")
    }
}
