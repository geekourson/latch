//
//  LatchApp.swift
//  Latch — « Your sessions, still running. »
//

import SwiftUI

@main
struct LatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("Latch") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 860, minHeight: 460)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouvelle session") { app.newShortcut() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
