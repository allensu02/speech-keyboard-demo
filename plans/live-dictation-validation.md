# Live Dictation Prototype Validation

Updated November 5, 2026. This is the Phase 1 implementation and validation record for [the implementation plan](live-dictation.md).

## Implemented

- SwiftUI setup screen, microphone permission, English model preparation/download progress, Start/Stop, and explicit interrupted/error states.
- Continuous AVAudioEngine capture with the `audio` background mode. Bounded audio buffers feed an actor-isolated SpeechAnalyzer pipeline only when a keyboard receiver is active.
- Native SpeechTranscriber provisional/final results with no rewrite step or cloud fallback.
- Embedded keyboard extension with basic letters, shift, numbers/symbols, delete, space, return, keyboard switching, listening status, and Stop.
- Marked-text composition with final-result deduplication and invalidation on context/document changes. Text proxy interactions remain a device-test gate.
- Versioned App Group snapshots, cross-process locking, atomic replacement, boot-aware heartbeats, receiver ownership, acknowledgements, bounded pending text, and stale-session handling.
- App/keyboard App Group entitlements and a shared Xcode scheme with focused logic tests.

## Verified

The simulator tests and unsigned device build were rerun after renaming the project and identifiers. Signed installation, visual inspection, and user-reported ChatGPT results below refer to the earlier device build. The new bundle IDs and App Group require fresh provisioning, installation, and keyboard setup.

| Check | Result |
|---|---|
| Xcode | 26.1.1, build 17B100 |
| Simulator build | Passed, iPhone 17 Pro / iOS 26.1 |
| Device architecture build, signing disabled | Passed, iPhoneOS 26.1 SDK |
| Development-signed device build | Passed after the account owner accepted Apple's updated agreement |
| Physical installation | Installed successfully on the connected iPhone 17 Pro; both app and keyboard have the App Group entitlement |
| Live dictation in native ChatGPT | User confirmed: “The words appear live in ChatGPT.” This confirms the basic path, not the remaining edge-case or endurance tests. |
| XCTest | 18 tests passed, 0 failures, on iOS 26.1 simulator |
| Packaged app Info.plist | `UIBackgroundModes = [audio]`; microphone usage description present |
| Keyboard packaging | Embedded `SpeechKeyboard.appex`; keyboard service extension and Full Access request configured |
| Simulator launch | Passed; setup screen visually inspected with no clipping of the visible controls |
| Connected device | iPhone 17 Pro, iOS 26.6; paired, Developer Mode enabled, developer services available |
| Whitespace check | `git diff --check` passed |

The tests cover partial/final revisions, multiple finals per poll, duplicate results, changed range boundaries, Unicode, user edits, document/epoch changes, selections, missing sequence IDs, lease expiry and reboot, competing receiver ownership, Stop preservation, corrupt/oversized files, and snapshot round trips. They use synthetic events; they do **not** prove live recognition, background endurance, or ChatGPT compatibility.

## Device installation

The first development-signed build was attempted with the project's existing team. Apple's provisioning service initially returned:

> Unable to process request - PLA Update available

The account owner subsequently accepted the agreement. Retrying with automatic provisioning succeeded and produced dedicated profiles for the app and keyboard. The signed build installed successfully on the iPhone 17 Pro. After the rename, both entitlement files and the shared protocol use `group.com.allensu.SpeechKeyboardDemo`; this new group has not yet been provisioned or tested on the phone.

Remote launch was initially rejected because the phone was locked. After completing setup, the user reported that words appeared live in ChatGPT. This is user-observed evidence of the basic physical-device dictation path; editing, stopping, interruption, and endurance behavior remain to be tested. No agreement was accepted by the agent.

## Packaging detail

The generated Info.plist build setting did not emit `UIBackgroundModes` in the built product. A minimal `Speech Keyboard Demo/Info.plist` containing that array was therefore added and merged with Xcode's generated app metadata. It is excluded from Copy Bundle Resources. This is the only additional implementation source file beyond the plan's file list. Both simulator and unsigned device products were checked for the resulting array.

Xcode also updated the user's scheme-order preference when it detected the keyboard target. Personal workspace settings remain local and are excluded from the published project.

## Remaining Phase 1 gate

After provisioning and installing the renamed app:

1. Launch Speech Keyboard on the connected iPhone; complete microphone/model setup.
2. Enable Speech Keyboard in Settings → General → Keyboard → Keyboards → Add New Keyboard. Enable Full Access for Speech Keyboard.
3. Verify ordinary Speech Keyboard typing in ChatGPT with listening off, then enable listening in Speech Keyboard and return to ChatGPT.
4. Wait for the keyboard to show “Listening,” dictate several phrases, and verify provisional words revise in place and final words are not duplicated.
5. Test typed corrections, cursor movement, selection, Send, a second message, switching away/back, a silence interval, and keyboard Stop. Do not send test messages automatically.
6. Run five minutes without an attached debugger. Confirm the microphone indicator ends after Stop.
7. Measure first-word and finalization latency and assess repetitions/fillers with an agreed utterance set.

The user confirmed basic live insertion in the native ChatGPT composer on the test phone. Lock/interruption behavior, editing and Stop behavior, sustained background execution, and measured live cross-process timing are **not yet verified**. Do not mark the entire Phase 1 acceptance matrix complete from the happy-path report alone.

Later plan gates remain open: 30-minute endurance/energy testing, broader host-app coverage, and release-level accessibility/layout testing. No TestFlight or App Store publication has been performed.

## Reproducing local checks

From the project root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Speech Keyboard Demo.xcodeproj' -scheme 'Speech Keyboard Demo' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/speech-keyboard-derived CODE_SIGNING_ALLOWED=NO test

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Speech Keyboard Demo.xcodeproj' -scheme 'Speech Keyboard Demo' \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/speech-keyboard-device-build CODE_SIGNING_ALLOWED=NO build
```

The renamed project’s successful test result bundle is at `/tmp/speech-keyboard-rename-tests.xcresult`. Build and test logs are temporary artifacts under `/tmp/speech-keyboard-rename-*`; they are not committed source files.
