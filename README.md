# Speech Keyboard Demo

An iOS prototype that listens in the background and inserts live, on-device speech transcription into the focused text field through a custom keyboard.

Start listening in Speech Keyboard, switch to ChatGPT or another compatible app, select Speech Keyboard, and speak. You review and send the text yourself.

## Requirements

- Xcode 26.1.1 or later and an iPhone running iOS 26.1 or later.
- A device that supports Apple's `SpeechTranscriber` and its English language model. Availability is checked at runtime.
- An Apple developer team with App Groups provisioning available.
- Developer Mode enabled on the test iPhone.
- Internet access for the initial speech-model download if needed. Transcription itself runs on-device.

## Build and run

1. Open `Speech Keyboard Demo.xcodeproj` and select the **Speech Keyboard Demo** scheme.
2. Check **Signing & Capabilities** for both **Speech Keyboard Demo** and **SpeechKeyboard**. The project uses the original developer’s team and new bundle identifiers under `com.allensu.SpeechKeyboardDemo`. Enable automatic signing and provision the App Group `group.com.allensu.SpeechKeyboardDemo` for both targets.
3. If using another developer account, choose your team, use bundle identifiers you own, and register an App Group you own. Update the group identifier in both entitlement files and `Shared/SessionProtocol.swift` so all three match.
4. Select your connected iPhone and run the app.
5. On the phone, go to **Settings → General → Keyboard → Keyboards → Add New Keyboard**, add **Speech Keyboard**, then enable **Allow Full Access** for it.
6. Open Speech Keyboard and tap **Start listening**. Grant microphone permission and let the model preparation finish.
7. Open ChatGPT, focus its message box, select Speech Keyboard using the globe key, and wait for **Listening** before speaking.
8. Use **Stop** on the keyboard or **Stop listening** in Speech Keyboard when finished.

Full Access lets the keyboard exchange transcripts and controls with the main app through shared storage. The keyboard does not access the microphone; the main app owns recording. No cloud transcription service or API key is used.

## How it works

```text
Microphone → Speech Keyboard app → SpeechAnalyzer / SpeechTranscriber
                               ↓
                      Shared App Group snapshots
                               ↓
                      Speech Keyboard extension → Focused text field
```

The app maintains microphone capture while listening is enabled. Audio is transcribed only when a current keyboard receiver is ready; speech outside that context is discarded. Provisional results use marked-text composition, and finalized results are committed once. Session IDs, field epochs, acknowledgements, and expiring leases prevent old results from being replayed into new fields.

Raw audio and transcript history are not retained. Small protected transcript snapshots exist temporarily for delivery. Logs omit speech and surrounding host text.

## Validation and limitations

- The renamed project passes simulator tests and an unsigned device build. Development signing and installation succeeded before the identifier change; the new identifiers still need provisioning and a fresh device install.
- All 18 automated tests passed.
- Before the identifier change, the prototype was installed on an iPhone 17 Pro running iOS 26.6. The tester confirmed that words appeared live in the native ChatGPT app.
- Extended device tests for manual edits, cursor movement, stopping, interruptions, and sustained background use are still pending. This is a prototype, not a production release.
- Secure fields, some phone-number fields, and apps that reject third-party keyboards are unsupported.
- Calls, Siri, other microphone users, force-quitting, or iOS resource management can interrupt listening. Recognition may mishear or normalize words even though no rewrite step is applied.

Run the logic tests with the **Speech Keyboard Demo** scheme in Xcode, or:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Speech Keyboard Demo.xcodeproj' -scheme 'Speech Keyboard Demo' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/speech-keyboard-derived CODE_SIGNING_ALLOWED=NO test
```

See the [implementation plan](plans/live-dictation.md) and [validation record](plans/live-dictation-validation.md) for architecture, test coverage, and remaining acceptance criteria.
