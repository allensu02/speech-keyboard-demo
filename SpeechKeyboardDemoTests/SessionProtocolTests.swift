import XCTest

final class SessionProtocolTests: XCTestCase {
    func testLeaseRejectsOldBootFutureTimestampAndExpiry() {
        let time = BridgeTime(boot: "boot-a", uptime: 100)
        XCTAssertTrue(time.isFresh(at: .init(boot: "boot-a", uptime: 101)))
        XCTAssertFalse(time.isFresh(at: .init(boot: "boot-b", uptime: 101)))
        XCTAssertFalse(time.isFresh(at: .init(boot: "boot-a", uptime: 99)))
        XCTAssertFalse(time.isFresh(at: .init(boot: "boot-a", uptime: 102)))
    }

    func testReceiverCannotCrossSessionsOrRemainActiveAfterRelease() {
        let session = UUID()
        var receiver = ReceiverSnapshot(sessionID: session, instanceID: UUID(), epoch: UUID(), heartbeat: .init(boot: "a", uptime: 1))
        let now = BridgeTime(boot: "a", uptime: 1.5)
        XCTAssertTrue(receiver.isValid(for: session, at: now))
        XCTAssertFalse(receiver.isValid(for: UUID(), at: now))
        receiver.active = false
        XCTAssertFalse(receiver.isValid(for: session, at: now))
    }

    func testMalformedTranscriptRangesAreRejected() {
        let segment = SpeechSegment(id: 1, start: 2, end: 1, text: "bad")
        let update = TranscriptSnapshot(sessionID: UUID(), epoch: UUID(), revision: 1, finals: [segment], provisional: "")
        XCTAssertFalse(update.hasValidPayload)
    }
}
