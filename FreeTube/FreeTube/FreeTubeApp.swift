//
//  FreeTubeApp.swift
//  FreeTube
//
//  Created by leshko on 17/5/26.
//
//  CLAUDE.md says iOS 16.0+, but SwiftData and `@Observable` require iOS 17.0+. The deployment
//  target should be bumped to 17.0 in the Xcode project; this file requires iOS 17.
//

import SwiftUI
import SwiftData

@main
@available(iOS 17.0, *)
struct FreeTubeApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment.playerStateManager)
                .modelContainer(PersistenceController.sharedContainer)
                // Dark-only appearance app-wide. No user-facing toggle — the player chrome,
                // mini-player bar, and full-screen content are all designed for dark.
                .preferredColorScheme(.dark)
        }
        // Menu-bar items + keyboard shortcuts. Only meaningful on Mac (via "Designed for
        // iPad on Mac" — Catalyst would also pick them up if we ever enable it), but
        // harmless to register everywhere — iPhone shows no menu bar, iPad-with-keyboard
        // picks up the shortcuts which is a fine bonus. See `MacCommands`.
        .commands {
            MacCommands(player: appEnvironment.playerStateManager)
        }
    }
}
