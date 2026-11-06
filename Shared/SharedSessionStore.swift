import Foundation
import Darwin

/// All bridge operations hold a short advisory lock, including receiver ownership transfers.
/// Never call from an audio render callback. Atomic replacement prevents partial JSON reads.
nonisolated final class SharedSessionStore: @unchecked Sendable {
    enum File: String { case session, receiver, transcript }
    private let directory: URL

    init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DictationBridge.groupID) else {
                throw DictationError.sharedContainer
            }
            self.directory = group.appendingPathComponent("LiveDictation", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var url = self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    func read<T: Decodable>(_ file: File, as type: T.Type = T.self) throws -> T? {
        try locked { try readUnlocked(file, as: type) }
    }

    func write<T: Encodable>(_ value: T, to file: File) throws {
        try locked { try writeUnlocked(value, to: file) }
    }

    func remove(_ file: File) throws {
        try locked {
            let url = path(file)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func claim(_ receiver: ReceiverSnapshot) throws {
        try locked {
            var receiver = receiver
            let old: ReceiverSnapshot? = try readUnlocked(.receiver)
            if old?.sessionID == receiver.sessionID { receiver.stopCommandID = old?.stopCommandID }
            try writeUnlocked(receiver, to: .receiver)
        }
    }

    func updateReceiver(instanceID: UUID, sessionID: UUID, _ change: (inout ReceiverSnapshot) -> Void) throws {
        try locked {
            guard var receiver: ReceiverSnapshot = try readUnlocked(.receiver),
                  receiver.instanceID == instanceID, receiver.sessionID == sessionID else {
                throw DictationError.ownershipLost
            }
            change(&receiver)
            try writeUnlocked(receiver, to: .receiver)
        }
    }

    private func path(_ file: File) -> URL { directory.appendingPathComponent(file.rawValue + ".json") }

    private func readUnlocked<T: Decodable>(_ file: File, as type: T.Type = T.self) throws -> T? {
        let url = path(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= DictationBridge.maximumBytes else { throw DictationError.overflow }
        let data = try Data(contentsOf: url)
        guard data.count <= DictationBridge.maximumBytes else { throw DictationError.overflow }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DictationError.invalidData }
    }

    private func writeUnlocked<T: Encodable>(_ value: T, to file: File) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= DictationBridge.maximumBytes else { throw DictationError.overflow }
        #if os(iOS)
        try data.write(to: path(file), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: path(file), options: .atomic)
        #endif
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(directory.appendingPathComponent("bridge.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DictationError.sharedContainer }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DictationError.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
