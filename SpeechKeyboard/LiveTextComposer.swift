import Foundation

@MainActor protocol DictationTextProxy: AnyObject {
    var documentID: UUID { get }
    var before: String? { get }
    var after: String? { get }
    var selection: String? { get }
    func mark(_ text: String)
    func commit()
}

/// Owns one marked composition. Never deletes surrounding text to repair a mismatch.
@MainActor final class LiveTextComposer {
    struct Context: Equatable {
        var document: UUID
        var before: String?
        var after: String?
        var selection: String?
        @MainActor init(_ proxy: any DictationTextProxy) {
            document = proxy.documentID
            before = proxy.before.map { String($0.suffix(160)) }
            after = proxy.after.map { String($0.prefix(80)) }
            selection = proxy.selection
        }
    }
    enum Failure: Error { case contextChanged, wrongEpoch, invalidSequence }
    private(set) var epoch: UUID?
    private(set) var lastFinalID = 0
    private(set) var revision = -1
    private(set) var isMutating = false
    private var expected: Context?
    private var marked = false
    private var prefix = ""

    func begin(epoch: UUID, proxy: any DictationTextProxy) throws {
        guard proxy.selection?.isEmpty != false else { throw Failure.contextChanged }
        self.epoch = epoch
        lastFinalID = 0
        revision = -1
        marked = false
        expected = Context(proxy)
        if let last = proxy.before?.last, !last.isWhitespace, !"([{/-".contains(last) { prefix = " " }
        else { prefix = "" }
    }

    func ownsContext(_ proxy: any DictationTextProxy) -> Bool {
        epoch != nil && Context(proxy) == expected
    }

    func apply(_ update: TranscriptSnapshot, proxy: any DictationTextProxy) throws {
        guard update.epoch == epoch else { throw Failure.wrongEpoch }
        guard ownsContext(proxy) else { throw Failure.contextChanged }
        guard update.hasValidPayload else { throw Failure.invalidSequence }
        guard update.revision > revision else { return }
        isMutating = true
        defer { isMutating = false; expected = Context(proxy) }
        for segment in update.finals where segment.id > lastFinalID {
            guard segment.id == lastFinalID + 1 else { throw Failure.invalidSequence }
            let text = prefixed(segment.text)
            if !text.isEmpty || marked {
                proxy.mark(text)
                proxy.commit()
                marked = false
            }
            if !segment.text.isEmpty { prefix = "" }
            lastFinalID = segment.id
        }
        if !update.provisional.isEmpty {
            proxy.mark(prefixed(update.provisional))
            marked = true
        } else if marked {
            proxy.mark("")
            proxy.commit()
            marked = false
        }
        revision = update.revision
    }

    /// Retain the currently displayed words only if the proxy is still ours.
    func end(proxy: any DictationTextProxy) {
        if marked && ownsContext(proxy) {
            isMutating = true
            proxy.commit()
            isMutating = false
        }
        epoch = nil
        expected = nil
        marked = false
    }

    private func prefixed(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace, !".,!?;:)]}".contains(first) else { return text }
        return prefix + text
    }
}
