import XCTest

@MainActor private final class FakeProxy: DictationTextProxy {
    var documentID = UUID()
    var text = ""
    var markedStart: String.Index?
    var before: String? { text }
    var after: String? { "" }
    var selection: String?
    var commits = 0
    var marks = 0
    func mark(_ value: String) {
        if let markedStart { text = String(text[..<markedStart]) }
        markedStart = text.endIndex
        text += value
        marks += 1
    }
    func commit() { markedStart = nil; commits += 1 }
}

final class LiveTextComposerTests: XCTestCase {
    @MainActor func testPartialRevisionFinalAndDuplicateDelivery() async throws {
        let proxy = FakeProxy(), composer = LiveTextComposer(), epoch = UUID(), session = UUID()
        try composer.begin(epoch: epoch, proxy: proxy)
        var update = TranscriptSnapshot(sessionID: session, epoch: epoch, revision: 1, finals: [], provisional: "I scream")
        try composer.apply(update, proxy: proxy)
        update.revision = 2; update.provisional = "ice cream"
        try composer.apply(update, proxy: proxy)
        XCTAssertEqual(proxy.text, "ice cream")
        update.revision = 3; update.provisional = ""
        update.finals = [.init(id: 1, start: 0, end: 1, text: "Ice cream.")]
        try composer.apply(update, proxy: proxy)
        try composer.apply(update, proxy: proxy)
        XCTAssertEqual(proxy.text, "Ice cream.")
        XCTAssertEqual(proxy.commits, 1)
        XCTAssertEqual(composer.lastFinalID, 1)
    }

    @MainActor func testFinalsAndFollowingPartialArriveTogether() async throws {
        let proxy = FakeProxy(), composer = LiveTextComposer(), epoch = UUID()
        try composer.begin(epoch: epoch, proxy: proxy)
        let update = TranscriptSnapshot(sessionID: UUID(), epoch: epoch, revision: 3, finals: [
            .init(id: 1, start: 0, end: 1, text: "One."), .init(id: 2, start: 1, end: 2, text: " Two.")
        ], provisional: " Three")
        try composer.apply(update, proxy: proxy)
        XCTAssertEqual(proxy.text, "One. Two. Three")
        XCTAssertEqual(proxy.commits, 2)
    }

    @MainActor func testExternalEditPreventsReplacement() async throws {
        let proxy = FakeProxy(), composer = LiveTextComposer(), epoch = UUID()
        try composer.begin(epoch: epoch, proxy: proxy)
        var update = TranscriptSnapshot(sessionID: UUID(), epoch: epoch, revision: 1, finals: [], provisional: "draft")
        try composer.apply(update, proxy: proxy)
        proxy.text = "User's correction"
        update.revision = 2; update.provisional = "overwrite"
        XCTAssertThrowsError(try composer.apply(update, proxy: proxy))
        composer.end(proxy: proxy)
        XCTAssertEqual(proxy.text, "User's correction")
        XCTAssertEqual(proxy.commits, 0)
    }

    @MainActor func testDifferentDocumentAndOldEpochCannotReceiveText() async throws {
        let proxy = FakeProxy(), composer = LiveTextComposer(), epoch = UUID()
        try composer.begin(epoch: epoch, proxy: proxy)
        let update = TranscriptSnapshot(sessionID: UUID(), epoch: epoch, revision: 1, finals: [], provisional: "old speech")
        proxy.documentID = UUID()
        XCTAssertThrowsError(try composer.apply(update, proxy: proxy))
        composer.end(proxy: proxy)
        try composer.begin(epoch: UUID(), proxy: proxy)
        XCTAssertThrowsError(try composer.apply(update, proxy: proxy))
        XCTAssertEqual(proxy.text, "")
    }

    @MainActor func testSelectionIsNotOverwrittenAndUnicodeSurvives() async throws {
        let proxy = FakeProxy(), composer = LiveTextComposer(), epoch = UUID()
        proxy.selection = "selected"
        XCTAssertThrowsError(try composer.begin(epoch: epoch, proxy: proxy))
        proxy.selection = nil
        proxy.text = "Existing"
        try composer.begin(epoch: epoch, proxy: proxy)
        let update = TranscriptSnapshot(sessionID: UUID(), epoch: epoch, revision: 1, finals: [
            .init(id: 1, start: 0, end: 1, text: "café 👨‍👩‍👧‍👦")
        ], provisional: "")
        try composer.apply(update, proxy: proxy)
        XCTAssertEqual(proxy.text, "Existing café 👨‍👩‍👧‍👦")
    }

    @MainActor func testMissingFinalSequenceFailsWithoutAppending() async throws {
        let proxy = FakeProxy(), composer = LiveTextComposer(), epoch = UUID()
        try composer.begin(epoch: epoch, proxy: proxy)
        let update = TranscriptSnapshot(sessionID: UUID(), epoch: epoch, revision: 1, finals: [.init(id: 2, start: 1, end: 2, text: "gap")], provisional: "")
        XCTAssertThrowsError(try composer.apply(update, proxy: proxy))
        XCTAssertEqual(proxy.text, "")
    }
}
