//
//  SpeechKeyboardDemoApp.swift
//  Speech Keyboard Demo
//
//  Created by Allen Su on 11/5/26.
//

import SwiftUI

@main
struct SpeechKeyboardDemoApp: App {
    @State private var session = DictationSession()
    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
    }
}
