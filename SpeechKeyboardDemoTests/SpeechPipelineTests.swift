import XCTest

final class SpeechPipelineTests: XCTestCase {
    func testRevisionsReplacePartialAndFinalIsRetainedUntilAcknowledged() throws {
        var buffer = TranscriptBuffer()
        try buffer.receive(start: 0, end: 1, text: "I scream", isFinal: false)
        try buffer.receive(start: 0, end: 1.2, text: "ice cream", isFinal: false)
        XCTAssertEqual(buffer.provisional, "ice cream")
        try buffer.receive(start: 0, end: 1.2, text: "Ice cream.", isFinal: true)
        XCTAssertEqual(buffer.finals.map(\.text), ["Ice cream."])
        XCTAssertEqual(buffer.provisional, "")
        try buffer.receive(start: 0, end: 1.2, text: "Ice cream.", isFinal: true)
        XCTAssertEqual(buffer.finals.count, 1)
        try buffer.acknowledge(through: 1)
        XCTAssertTrue(buffer.finals.isEmpty)
    }

    func testMultipleFinalsSurviveOneSlowKeyboardPoll() throws {
        var buffer = TranscriptBuffer()
        try buffer.receive(start: 0, end: 1, text: "One.", isFinal: true)
        try buffer.receive(start: 1, end: 2, text: " Two.", isFinal: true)
        try buffer.receive(start: 2, end: 3, text: " Three", isFinal: false)
        XCTAssertEqual(buffer.finals.map(\.id), [1, 2])
        try buffer.acknowledge(through: 1)
        XCTAssertEqual(buffer.finals.map(\.id), [2])
        XCTAssertEqual(buffer.provisional, " Three")
    }

    func testRegressingAcrossFinalBoundaryIsRejected() throws {
        var buffer = TranscriptBuffer()
        try buffer.receive(start: 0, end: 1, text: "Done.", isFinal: true)
        XCTAssertThrowsError(try buffer.receive(start: 0.5, end: 2, text: "Changed", isFinal: false))
    }

    func testChangingPartialBoundariesDoesNotAppendGuesses() throws {
        var buffer = TranscriptBuffer()
        try buffer.receive(start: 0, end: 1, text: "one", isFinal: false)
        try buffer.receive(start: 1, end: 2, text: " two", isFinal: false)
        try buffer.receive(start: 0, end: 2, text: "One two.", isFinal: true)
        XCTAssertEqual(buffer.provisional, "")
        XCTAssertEqual(buffer.finals.map(\.text), ["One two."])
    }

    func testStalledDeliveryAndOversizedOutputAreExplicitFailures() throws {
        var buffer = TranscriptBuffer()
        try buffer.receive(start: 0, end: 1, text: "Pending", isFinal: true, now: .init(boot: "a", uptime: 1))
        XCTAssertThrowsError(try buffer.acknowledge(through: 0, now: .init(boot: "a", uptime: 32)))
        var oversized = TranscriptBuffer()
        XCTAssertThrowsError(try oversized.receive(start: 0, end: 1, text: String(repeating: "a", count: 50_000), isFinal: false))
    }
}
