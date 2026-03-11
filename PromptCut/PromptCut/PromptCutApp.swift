//
//  PromptCutApp.swift
//  PromptCut
//

import SwiftUI

@main
struct PromptCutApp: App {
    init() {
        Analytics.setup()
        Analytics.trackAppLaunched()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 640)
        .commands {
            // Remove the default New Window command
            CommandGroup(replacing: .newItem) {}
        }
    }
}
