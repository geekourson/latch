//
//  LatchApp.swift
//  Latch — « Your sessions, still running. »
//

import AppKit
import SwiftUI

@main
struct LatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()
    @StateObject private var updater = Updater()

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
            CommandGroup(after: .appInfo) {
                if updater.isAvailable {
                    Button(localized("Rechercher les mises à jour…")) { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            // ⌘W ferme le terminal au premier plan, comme la croix d'un onglet
            // le faisait. Ailleurs — les Réglages, ou une fenêtre principale
            // sans terminal —, il ferme la fenêtre, comme partout sur macOS.
            CommandGroup(replacing: .saveItem) {
                Button(localized("Fermer")) {
                    let window = NSApp.keyWindow
                    if window?.identifier == WindowChrome.mainWindowIdentifier,
                       app.selectedTab != nil {
                        app.closeSelectedTab()
                    } else {
                        window?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
            }
            CommandGroup(after: .pasteboard) {
                Button(localized("Copier l'historique de la fenêtre")) { app.copySelectedHistory() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!app.canCopyHistory)
            }
            CommandGroup(replacing: .newItem) {
                Button(localized("Nouvelle session")) { app.newShortcut() }
                    .keyboardShortcut("n")
                Button(localized("Nouvelle fenêtre")) { app.newWindowInSelectedSession() }
                    .keyboardShortcut("t")
            }
            CommandGroup(after: .windowArrangement) {
                Button(localized("Fenêtre suivante")) { app.selectAdjacentWindow(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button(localized("Fenêtre précédente")) { app.selectAdjacentWindow(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(updater)
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
