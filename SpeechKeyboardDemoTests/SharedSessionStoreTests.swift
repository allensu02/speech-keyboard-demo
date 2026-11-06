import XCTest

final class SharedSessionStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testNewOwnerPreventsOldInstanceFromRenewingAndPreservesStop() throws {
        let store = try SharedSessionStore(directory: directory()), session = UUID()
        var first = ReceiverSnapshot(sessionID: session, instanceID: UUID(), epoch: UUID())
        first.stopCommandID = UUID()
        try store.claim(first)
        let second = ReceiverSnapshot(sessionID: session, instanceID: UUID(), epoch: UUID())
        try store.claim(second)
        XCTAssertThrowsError(try store.updateReceiver(instanceID: first.instanceID, sessionID: session) { $0.active = true })
        let actual: ReceiverSnapshot? = try store.read(.receiver)
        XCTAssertEqual(actual?.instanceID, second.instanceID)
        XCTAssertEqual(actual?.stopCommandID, first.stopCommandID)
    }

    func testRoundTripRemovalAndNewSessionDropsOldStop() throws {
        let store = try SharedSessionStore(directory: directory())
        let first = ReceiverSnapshot(sessionID: UUID(), instanceID: UUID(), epoch: UUID(), stopCommandID: UUID())
        try store.claim(first)
        let second = ReceiverSnapshot(sessionID: UUID(), instanceID: UUID(), epoch: UUID())
        try store.claim(second)
        let actual: ReceiverSnapshot? = try store.read(.receiver)
        XCTAssertNil(actual?.stopCommandID)
        try store.remove(.receiver)
        let absent: ReceiverSnapshot? = try store.read(.receiver)
        XCTAssertNil(absent)
    }

    func testCorruptAndOversizedDataFailClosed() throws {
        let directory = try directory(), store = try SharedSessionStore(directory: directory)
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try store.read(.session, as: SessionSnapshot.self))
        let data = Data(repeating: 65, count: DictationBridge.maximumBytes + 1)
        try data.write(to: directory.appendingPathComponent("transcript.json"))
        XCTAssertThrowsError(try store.read(.transcript, as: TranscriptSnapshot.self))
    }

    func testAtomicSnapshotCanBeReadBySeparateStoreInstance() throws {
        let directory = try directory()
        let writer = try SharedSessionStore(directory: directory)
        let reader = try SharedSessionStore(directory: directory)
        for index in 0..<100 {
            let snapshot = SessionSnapshot(sessionID: UUID(), state: .waitingForField, message: "status \(index)")
            try writer.write(snapshot, to: .session)
            let read: SessionSnapshot? = try reader.read(.session)
            XCTAssertEqual(read?.sessionID, snapshot.sessionID)
        }
    }
}
