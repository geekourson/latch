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
            // ⌘W ferme la zone active, comme sa croix. Ailleurs — les
            // Réglages —, il ferme la fenêtre, comme partout sur macOS.
            CommandGroup(replacing: .saveItem) {
                Button(localized("Fermer la zone")) {
                    let window = NSApp.keyWindow
                    if window?.identifier == WindowChrome.mainWindowIdentifier {
                        app.closeFocusedZone()
                    } else {
                        window?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
            }
            CommandMenu(localized("Zones")) {
                Button(localized("Couper à droite")) { app.splitFocusedZone(.horizontal) }
                    .keyboardShortcut("d")
                Button(localized("Couper en dessous")) { app.splitFocusedZone(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(localized("Agrandir ou revenir")) { app.toggleZoomOfFocusedZone() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(app.layout.isSingle)
                Button(localized("Verrouiller ou déverrouiller")) { app.toggleLockOfFocusedZone() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(app.focusedZone?.sessionID == nil)
                Divider()
                Button(localized("Zone à gauche")) { app.focusNeighbour(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button(localized("Zone à droite")) { app.focusNeighbour(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button(localized("Zone au-dessus")) { app.focusNeighbour(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(localized("Zone en dessous")) { app.focusNeighbour(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.title) { app.apply(preset) }
                }
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
