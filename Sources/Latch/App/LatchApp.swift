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
                Button(localized("Nouvelle session")) { app.newShortcut() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                // Une scène à part : la locale de ContentView ne l'atteint pas.
                .environment(\.locale, Locale(identifier: app.store.preferences.language.resolved))
                .id(app.store.preferences.language)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
