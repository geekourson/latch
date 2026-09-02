//
//  SettingsView.swift
//  Latch
//
//  Les réglages d'apparence du §9.3 : police mono configurable, interligne, et
//  import de thèmes aux formats iTerm2 et base16 — Latch n'invente pas de
//  format maison.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var importError: String?

    private var store: SessionStore { app.store }

    var body: some View {
        Form {
            Section("Langue") {
                Picker("Interface", selection: languageBinding) {
                    ForEach(Language.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                Text("Le changement s'applique tout de suite.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.latchTextFaint)
            }

            Section("Terminal") {
                Picker("Police", selection: fontBinding) {
                    Text("Automatique").tag("")
                    Divider()
                    ForEach(LatchTheme.availableMonoFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                Slider(
                    value: Binding(
                        get: { store.preferences.fontSize },
                        set: { store.preferences.fontSize = $0; store.scheduleSave() }
                    ),
                    in: 9...24,
                    step: 0.5
                ) {
                    Text("Corps  \(store.preferences.fontSize, specifier: "%.1f")")
                }

                Slider(
                    value: Binding(
                        get: { store.preferences.lineSpacing },
                        set: { store.preferences.lineSpacing = $0; store.scheduleSave() }
                    ),
                    in: 1.0...2.0,
                    step: 0.05
                ) {
                    Text("Interligne  \(store.preferences.lineSpacing, specifier: "%.2f")")
                }
            }

            Section("Thème") {
                Picker("Palette", selection: themeBinding) {
                    Text("Braise (intégré)").tag(UUID?.none)
                    ForEach(store.themes) { theme in
                        Text("\(theme.name)  ·  \(theme.source.label)").tag(UUID?.some(theme.id))
                    }
                }

                ThemePreview(theme: store.activeTheme)

                HStack {
                    Button("Importer un thème…") { importTheme() }
                    if let id = store.preferences.themeID {
                        Button("Retirer") { store.removeTheme(id: id) }
                    }
                    Spacer()
                }

                Text.paragraph("Formats acceptés : .itermcolors (iTerm2) et les schémas "
                    + "base16 en .yaml.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.latchTextFaint)

                if let importError {
                    Text(importError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.latchAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Ligatures") {
                Text.paragraph("SwiftTerm dessine glyphe par glyphe sur une grille de "
                    + "cellules et n'expose aucun réglage de ligatures : il n'y "
                    + "a rien à activer ici tant que l'émulateur ne le permet pas.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }

    // MARK: Liaisons

    private var languageBinding: Binding<Language> {
        Binding(
            get: { store.preferences.language },
            set: { store.setLanguage($0) }
        )
    }

    private var fontBinding: Binding<String> {
        Binding(
            get: { store.preferences.fontName ?? "" },
            set: {
                store.preferences.fontName = $0.isEmpty ? nil : $0
                store.scheduleSave()
            }
        )
    }

    private var themeBinding: Binding<UUID?> {
        Binding(
            get: { store.preferences.themeID },
            set: { store.preferences.themeID = $0; store.scheduleSave() }
        )
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "itermcolors") ?? .data,
            UTType(filenameExtension: "yaml") ?? .yaml,
            .yaml,
            .propertyList,
        ]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.importTheme(at: url)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Aperçu

private struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(theme.ansi.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(color.nsColor))
                        .frame(height: 16)
                }
            }

            Text("latch on to billy")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(theme.foreground.nsColor))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color(theme.background.nsColor))
                )
        }
    }
}
