// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import AVFoundation
import SwiftUI

@main
struct PersistentAVPlayerItemDemoApp: App {
    init() {
        // Muted background videos shouldn't interrupt the user's music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
