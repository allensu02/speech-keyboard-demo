import UIKit

@MainActor final class KeyboardViewController: UIInputViewController, DictationTextProxy {
    private let keyboard = KeyboardView()
    private let composer = LiveTextComposer()
    private let instanceID = UUID()
    private var store: SharedSessionStore?
    private var session: SessionSnapshot?
    private var receiver: ReceiverSnapshot?
    private var pollTask: Task<Void, Never>?
    private var visible = false
    private var stopping = false
    private var ownsReceiver = false
    private var nextConnectionAt = Date.distantPast

    var documentID: UUID { textDocumentProxy.documentIdentifier }
    var before: String? { textDocumentProxy.documentContextBeforeInput }
    var after: String? { textDocumentProxy.documentContextAfterInput }
    var selection: String? { textDocumentProxy.selectedText }
    func mark(_ text: String) { textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0)) }
    func commit() { textDocumentProxy.unmarkText() }

    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true
        primaryLanguage = "en-US"
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)
        let height = view.heightAnchor.constraint(equalToConstant: 272)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor), height
        ])
        keyboard.onStop = { [weak self] in self?.requestStop() }
        keyboard.onKey = { [weak self] key in self?.type(key) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        ownsReceiver = false
        nextConnectionAt = .distantPast
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        pollTask?.cancel()
        disconnect()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) { checkForExternalEdit() }
    override func selectionDidChange(_ textInput: (any UITextInput)?) { checkForExternalEdit() }

    private func checkForExternalEdit() {
        guard !composer.isMutating, composer.epoch != nil, !composer.ownsContext(self) else { return }
        disconnect()
        nextConnectionAt = Date().addingTimeInterval(0.35)
    }

    private func poll() {
        guard visible else { return }
        guard hasFullAccess else {
            disconnect()
            store = nil
            keyboard.show("Enable Full Access for dictation. Typing still works.", canStop: false)
            return
        }
        do {
            if store == nil { store = try SharedSessionStore() }
            guard let store, let status: SessionSnapshot = try store.read(.session) else {
                keyboard.show("Open Speech Keyboard to start listening", canStop: false)
                return
            }
            if session?.sessionID != status.sessionID { disconnect(); stopping = false }
            session = status
            if status.state == .idle || status.state == .failed || status.state == .interrupted {
                // Consume a final snapshot only for the same still-owned field before retiring it.
                if status.isFresh(), let receiver, status.epoch == receiver.epoch { try applyLatest(store, receiver: receiver) }
                disconnect()
                stopping = false
                keyboard.show(status.message ?? "Open Speech Keyboard to start listening", canStop: false)
                return
            }
            guard status.isFresh() else {
                disconnect()
                keyboard.show("Connection lost. Open Speech Keyboard to check listening.", canStop: false)
                return
            }
            guard status.state.isCapturing || status.state == .stopping else {
                keyboard.show("Finish setup in Speech Keyboard", canStop: false)
                return
            }
            guard selection?.isEmpty != false else {
                disconnect()
                keyboard.show("Place the cursor to resume dictation", canStop: true)
                return
            }
            checkForExternalEdit()
            if receiver == nil, !stopping, status.state.isCapturing, Date() >= nextConnectionAt {
                let next = ReceiverSnapshot(sessionID: status.sessionID, instanceID: instanceID, epoch: UUID())
                try composer.begin(epoch: next.epoch, proxy: self)
                try store.claim(next)
                receiver = next
                ownsReceiver = true
            }
            if let receiver, ownsReceiver {
                try store.updateReceiver(instanceID: instanceID, sessionID: receiver.sessionID) {
                    $0.heartbeat = .now
                    $0.lastFinalID = composer.lastFinalID
                }
                if status.epoch == receiver.epoch, status.state == .transcribing || status.state == .stopping {
                    try applyLatest(store, receiver: receiver)
                }
            }
            let ready = status.state == .transcribing && status.epoch == receiver?.epoch
            keyboard.show(stopping || status.state == .stopping ? "Stopping…" : (ready ? "Listening · On device" : "Connecting…"), canStop: !stopping)
        } catch DictationError.busy {
            // Short contention; retry on the next tick.
        } catch DictationError.ownershipLost {
            composer.end(proxy: self)
            receiver = nil
            ownsReceiver = false
            // Do not fight a newer visible keyboard for the lease.
            nextConnectionAt = .distantFuture
            keyboard.show("Dictation moved to another text field", canStop: false)
        } catch {
            disconnect()
            nextConnectionAt = Date().addingTimeInterval(0.5)
            keyboard.show("Dictation paused. Place the cursor or reopen Speech Keyboard.", canStop: session?.state.isCapturing == true)
        }
    }

    private func applyLatest(_ store: SharedSessionStore, receiver: ReceiverSnapshot) throws {
        guard let update: TranscriptSnapshot = try store.read(.transcript), update.sessionID == receiver.sessionID,
              update.epoch == receiver.epoch, update.heartbeat.isFresh(at: .now) else { return }
        try composer.apply(update, proxy: self)
        try store.updateReceiver(instanceID: instanceID, sessionID: receiver.sessionID) { $0.lastFinalID = composer.lastFinalID }
    }

    private func requestStop() {
        guard let store, let session, session.state.isCapturing else { return }
        do {
            if receiver == nil {
                let next = ReceiverSnapshot(sessionID: session.sessionID, instanceID: instanceID, epoch: UUID(), active: false)
                try store.claim(next)
                receiver = next
                ownsReceiver = true
            }
            try store.updateReceiver(instanceID: instanceID, sessionID: session.sessionID) {
                $0.stopCommandID = $0.stopCommandID ?? UUID()
                $0.heartbeat = .now
            }
            stopping = true
            keyboard.show("Stopping…", canStop: false)
        } catch {
            keyboard.show("Open Speech Keyboard to stop listening", canStop: true)
        }
    }

    private func type(_ key: KeyboardView.Key) {
        disconnect()
        nextConnectionAt = Date().addingTimeInterval(0.35)
        switch key {
        case .text(let text): textDocumentProxy.insertText(text)
        case .backspace: textDocumentProxy.deleteBackward()
        case .nextKeyboard: advanceToNextInputMode()
        }
    }

    private func disconnect() {
        composer.end(proxy: self)
        if let receiver, ownsReceiver {
            try? store?.updateReceiver(instanceID: instanceID, sessionID: receiver.sessionID) { $0.active = false }
        }
        receiver = nil
        ownsReceiver = false
    }
}
