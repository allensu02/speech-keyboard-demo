import SwiftUI

struct ContentView: View {
    let session: DictationSession
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(title, systemImage: session.state.isCapturing ? "waveform" : "mic")
                            .font(.title2.bold())
                        Text(session.message).foregroundStyle(.secondary)
                        if let progress = session.downloadProgress {
                            ProgressView(value: progress) { Text("Preparing English") }
                        } else if session.state == .preparing || session.state == .stopping { ProgressView() }
                        if let startedAt = session.startedAt {
                            HStack {
                                Text("Microphone active")
                                Spacer()
                                Text(startedAt, style: .timer).monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            if session.canStart { session.start() }
                            else { Task { await session.stop() } }
                        } label: {
                            Label(session.canStart ? "Start listening" : "Stop listening", systemImage: session.canStart ? "mic.fill" : "stop.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(session.canStart ? .accentColor : .red)
                        .disabled(session.state == .stopping)
                    }.padding(.vertical, 12)
                }
                Section("Set up once") {
                    step("1", "Add Speech Keyboard", "In Settings, open General → Keyboard → Keyboards → Add New Keyboard, then choose Speech Keyboard.")
                    step("2", "Allow Full Access", "Tap Speech Keyboard in that list and enable Allow Full Access. This lets the keyboard exchange text and Stop controls with this app.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Section("Then just speak") {
                    Text("Start listening here. Open ChatGPT, tap the message box, and use the globe key to select Speech Keyboard. Wait for “Listening” on the keyboard, then speak.")
                    Text("Keep Speech Keyboard selected to dictate into other compatible apps. You review and send the text yourself.").foregroundStyle(.secondary)
                }
                Section("Your microphone, your control") {
                    Text("Audio is processed on your iPhone. An internet connection may be needed to download the English speech model. Audio and transcript history are not saved.")
                    Text("The microphone stays active until you stop or iOS interrupts it. Speech outside an active Speech Keyboard text field is discarded. Password fields and some apps do not support custom keyboards.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Speech Keyboard")
        }
    }

    private var title: String {
        switch session.state {
        case .idle: "Speak where you type"
        case .preparing: "Getting ready"
        case .waitingForField: "Ready for a text field"
        case .connecting: "Connecting"
        case .transcribing: "Listening"
        case .stopping: "Stopping"
        case .interrupted: "Listening interrupted"
        case .failed: "Let’s reconnect"
        }
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.headline).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}
