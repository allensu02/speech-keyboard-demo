import Foundation
import Darwin

nonisolated enum DictationBridge {
    static let groupID = "group.com.allensu.SpeechKeyboardDemo"
    static let schema = 1
    static let leaseDuration: TimeInterval = 2
    static let maximumBytes = 65_536
    static let maximumPendingSeconds: TimeInterval = 30
}

nonisolated struct BridgeTime: Codable, Equatable, Sendable {
    var boot: String
    var uptime: TimeInterval

    static var now: Self { Self(boot: bootID, uptime: ProcessInfo.processInfo.systemUptime) }
    private static let bootID: String = {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return "unavailable" }
        return "\(value.tv_sec).\(value.tv_usec)"
    }()

    func isFresh(at now: Self, lifetime: TimeInterval = DictationBridge.leaseDuration) -> Bool {
        boot != "unavailable" && boot == now.boot && uptime.isFinite && now.uptime >= uptime
            && now.uptime - uptime < lifetime
    }
}

nonisolated enum CaptureState: String, Codable, Sendable {
    case idle, preparing, waitingForField, connecting, transcribing, stopping, interrupted, failed
    var isCapturing: Bool { self == .waitingForField || self == .connecting || self == .transcribing }
}

nonisolated struct SessionSnapshot: Codable, Sendable {
    var schema = DictationBridge.schema
    var sessionID: UUID
    var state: CaptureState
    var heartbeat: BridgeTime = .now
    var epoch: UUID?
    var acknowledgedStopID: UUID?
    var message: String?

    func isFresh(at now: BridgeTime = .now) -> Bool {
        schema == DictationBridge.schema && heartbeat.isFresh(at: now)
    }
}

nonisolated struct ReceiverSnapshot: Codable, Sendable {
    var schema = DictationBridge.schema
    var sessionID: UUID
    var instanceID: UUID
    var epoch: UUID
    var heartbeat: BridgeTime = .now
    var active = true
    var lastFinalID = 0
    var stopCommandID: UUID?

    func isValid(for session: UUID, at now: BridgeTime = .now) -> Bool {
        schema == DictationBridge.schema && sessionID == session && active && heartbeat.isFresh(at: now)
    }
}

nonisolated struct SpeechSegment: Codable, Equatable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
}

nonisolated struct TranscriptSnapshot: Codable, Sendable {
    var schema = DictationBridge.schema
    var sessionID: UUID
    var epoch: UUID
    var revision: Int
    var heartbeat: BridgeTime = .now
    var finals: [SpeechSegment]
    var provisional: String

    var hasValidPayload: Bool {
        schema == DictationBridge.schema && revision >= 0 && finals.count < 512
            && finals.allSatisfy { $0.id > 0 && $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
            && zip(finals, finals.dropFirst()).allSatisfy { $0.id < $1.id && $0.end <= $1.start }
    }
}

nonisolated enum DictationError: Error, LocalizedError {
    case sharedContainer, busy, invalidData, ownershipLost, overflow, unsupportedDevice, unsupportedLanguage
    case microphoneDenied, audioFormat, audioOverflow, recognitionOrder

    var errorDescription: String? {
        switch self {
        case .sharedContainer: "Shared access is unavailable. Check App Group signing in Xcode."
        case .busy: "The shared connection is busy."
        case .invalidData: "The dictation connection needs to be restarted."
        case .ownershipLost: "Another text field is now receiving dictation."
        case .overflow: "Text delivery fell behind. Stop and start listening again."
        case .unsupportedDevice: "On-device transcription is unavailable on this device. Use a supported iPhone."
        case .unsupportedLanguage: "English transcription is unavailable on this device."
        case .microphoneDenied: "Allow microphone access for Speech Keyboard in Settings, then try again."
        case .audioFormat: "This microphone format is unsupported. Try the built-in microphone."
        case .audioOverflow: "Audio processing fell behind. Start listening again."
        case .recognitionOrder: "Speech results changed unexpectedly. Start listening again."
        }
    }
}

/// Range-based reduction keeps final segments until the keyboard acknowledges them.
nonisolated struct TranscriptBuffer: Sendable {
    private(set) var finals: [SpeechSegment] = []
    private var partials: [SpeechSegment] = []
    private(set) var revision = 0
    private var nextID = 1
    private var finalizedThrough: Double = 0
    private var oldestPending: BridgeTime?
    var provisional: String { partials.sorted { $0.start < $1.start }.map(\.text).joined() }

    mutating func receive(start: Double, end: Double, text: String, isFinal: Bool, now: BridgeTime = .now) throws {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw DictationError.invalidData }
        if end <= finalizedThrough { return }
        guard start >= finalizedThrough else { throw DictationError.recognitionOrder }
        partials.removeAll { $0.start < end && $0.end > start || $0.start == start }
        let segment = SpeechSegment(id: nextID, start: start, end: end, text: text)
        if isFinal {
            // A final must not skip an earlier provisional range.
            guard !partials.contains(where: { $0.start < start }) else { throw DictationError.recognitionOrder }
            finals.append(segment)
            nextID += 1
            finalizedThrough = end
        } else {
            partials.append(segment)
        }
        revision += 1
        if oldestPending == nil { oldestPending = now }
        guard finals.reduce(provisional.utf8.count, { $0 + $1.text.utf8.count }) < 48_000 else {
            throw DictationError.overflow
        }
    }

    mutating func acknowledge(through id: Int, now: BridgeTime = .now) throws {
        let oldCount = finals.count
        finals.removeAll { $0.id <= id }
        if oldCount != finals.count { oldestPending = finals.isEmpty && partials.isEmpty ? nil : now }
        if let oldestPending, !oldestPending.isFresh(at: now, lifetime: DictationBridge.maximumPendingSeconds) {
            throw DictationError.overflow
        }
    }
}
