//
//  BuilderView.swift
//  Latch
//
//  L'écran du builder (SPEC §9.2) : des étapes empilées et réordonnables, une
//  carte par étape, et en bas l'aperçu de la commande générée — éditable.
//
//  Le glisser-déposer est contraint : un pré-vol ne peut pas passer après la
//  connexion, une fenêtre ne peut pas passer avant. Chaque section a son propre
//  `ForEach` avec son `onMove`, ce qui **refuse** le dépôt hors section au lieu
//  de désactiver la poignée.
//

import SwiftUI

struct BuilderView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var shortcut: Shortcut
    @State private var previewText: String = ""
    @State private var isEditingPreview = false
    @State private var isConnectionExpanded = true

    init(shortcut: Shortcut) {
        _shortcut = State(initialValue: shortcut)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Color.latchBorder)

            List {
                preflightSection
                connectionSection
                windowsSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 10)

            preview
        }
        .frame(width: 720, height: 660)
        .background(Color.latchBackground)
        .onAppear { refreshPreview() }
        .onChange(of: shortcut) { _, _ in refreshPreview() }
    }

    // MARK: - Barre de titre

    private var titleBar: some View {
        HStack(spacing: 10) {
            TextField("Nom", text: $shortcut.name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.latchText)

            Spacer()

            Button("Annuler") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("Enregistrer") {
                app.save(shortcut)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.latchAccent)
            .controlSize(.small)
            .disabled(!isSaveable)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var isSaveable: Bool {
        !shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty
            && (shortcut.isCustom || CommandBuilder.validate(shortcut).isEmpty)
    }

    // MARK: - 1. Pré-vol

    private var preflightSection: some View {
        Section {
            ForEach($shortcut.preflight) { $step in
                StepCard(badge: "local", isDeletable: true) {
                    app.errorMessage = nil
                    shortcut.preflight.removeAll { $0.id == step.id }
                } content: {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("Libellé", text: $step.label)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                        TextField("Commande locale", text: $step.command)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.latchTextDim)
                        Toggle(isOn: $step.failureIsFatal) {
                            Text(step.failureIsFatal
                                ? "Un échec annule la connexion"
                                : "Un échec avertit et laisse passer")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.latchTextFaint)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .onMove { source, destination in
                shortcut.preflight.move(fromOffsets: source, toOffset: destination)
            }

            AddRow(title: "Ajouter un pré-vol") {
                shortcut.preflight.append(Preflight(label: "Étape", command: ""))
            }
        } header: {
            SectionTitle("Pré-vol")
        }
    }

    // MARK: - 2. Connexion — une seule, non supprimable

    private var connectionSection: some View {
        Section {
            StepCard(
                badge: shortcut.connection.transport.label,
                isDeletable: false,
                isExpanded: $isConnectionExpanded
            ) {
            } content: {
                ConnectionFields(connection: $shortcut.connection)
            }
            .moveDisabled(true)
        } header: {
            SectionTitle("Connexion")
        }
    }

    // MARK: - 3. Fenêtres

    private var windowsSection: some View {
        Section {
            ForEach($shortcut.windows) { $window in
                StepCard(badge: "tmux", isDeletable: true) {
                    shortcut.windows.removeAll { $0.id == window.id }
                } content: {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("Nom de la fenêtre", text: $window.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                        TextField("Commande distante", text: $window.command)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.latchTextDim)
                    }
                }
            }
            .onMove { source, destination in
                shortcut.windows.move(fromOffsets: source, toOffset: destination)
            }

            AddRow(title: "Ajouter une fenêtre") {
                shortcut.windows.append(TmuxWindow(name: "fenêtre", command: ""))
            }
        } header: {
            SectionTitle("Fenêtres")
            Text("Créées à la première connexion seulement — aux suivantes, "
                + "tmux réattache la session telle qu'elle est.")
                .font(.system(size: 10))
                .foregroundStyle(Color.latchTextFaint)
                .textCase(nil)
        }
    }

    // MARK: - Aperçu éditable

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shortcut.isCustom ? "Commande personnalisée" : "Commande générée")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(shortcut.isCustom ? Color.latchAccent : Color.latchTextDim)

                Spacer()

                if shortcut.isCustom {
                    Button("Revenir au mode assisté") {
                        shortcut.customCommand = nil
                        refreshPreview()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchAccent)
                }
            }

            TextEditor(text: $previewText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color.latchText)
                .scrollContentBackground(.hidden)
                .frame(height: 56)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.latchSurface))
                .onChange(of: previewText) { _, newValue in
                    adoptEditedPreview(newValue)
                }

            ForEach(CommandBuilder.validate(shortcut)) { issue in
                if !shortcut.isCustom {
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.latchAccent)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.latchBackground)
    }

    private func refreshPreview() {
        isEditingPreview = true
        defer { isEditingPreview = false }
        previewText = (try? CommandBuilder.build(shortcut))
            ?? CommandBuilder.validate(shortcut).map(\.message).joined(separator: "\n")
    }

    /// Si l'utilisateur modifie l'aperçu, le raccourci bascule en mode
    /// personnalisé — mais retaper exactement la commande générée ne doit pas
    /// le faire basculer pour rien.
    private func adoptEditedPreview(_ text: String) {
        guard !isEditingPreview else { return }
        let generated = (try? CommandBuilder.build(shortcut, degradation: .none)) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if shortcut.isCustom {
            shortcut.customCommand = trimmed.isEmpty ? nil : trimmed
        } else if trimmed != generated.trimmingCharacters(in: .whitespacesAndNewlines) {
            shortcut.customCommand = trimmed
        }
    }
}

// MARK: - Champs de la connexion

private struct ConnectionFields: View {
    @Binding var connection: Connection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Transport", selection: $connection.transport) {
                ForEach(Transport.allCases) { transport in
                    Text(transport.label).tag(transport)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            if connection.transport.isRemote {
                Field("Hôte", placeholder: "alias ~/.ssh/config", text: $connection.host)
            }

            if connection.transport == .sshJump {
                Field(
                    "Rebond",
                    placeholder: "bastion",
                    text: Binding(
                        get: { connection.jumpHost ?? "" },
                        set: { connection.jumpHost = $0.isEmpty ? nil : $0 }
                    )
                )
            }

            Field("Session tmux", placeholder: "api", text: $connection.tmuxSession)

            Field(
                "Dossier",
                placeholder: "~/api",
                text: Binding(
                    get: { connection.workingDirectory ?? "" },
                    set: { connection.workingDirectory = $0.isEmpty ? nil : $0 }
                )
            )

            Picker("À la création", selection: initialCommandSelection) {
                ForEach(InitialCommandKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            if case .custom(let command) = connection.initialCommand {
                Field(
                    "Commande",
                    placeholder: "npm run dev",
                    text: Binding(
                        get: { command },
                        set: { connection.initialCommand = .custom($0) }
                    )
                )
            }

            Field(
                "Arguments",
                placeholder: "--model opus --permission-mode acceptEdits",
                text: Binding(
                    get: { connection.extraArgs ?? "" },
                    set: { connection.extraArgs = $0.isEmpty ? nil : $0 }
                )
            )

            Toggle(isOn: $connection.keepShellOnExit) {
                Text("Garder un shell après la sortie de la commande")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextDim)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $connection.controlMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mode contrôle (tmux -CC)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.latchTextDim)
                    if connection.transport == .mosh {
                        Text("Incompatible avec mosh — choisis ssh.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.latchAccent)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(connection.transport == .mosh)
        }
    }

    /// L'énumération du modèle porte une valeur associée ; le sélecteur, lui,
    /// a besoin d'un cas nu.
    private var initialCommandSelection: Binding<InitialCommandKind> {
        Binding(
            get: { InitialCommandKind(connection.initialCommand) },
            set: { kind in
                if case .custom = connection.initialCommand, kind == .custom { return }
                connection.initialCommand = kind.makeCommand()
            }
        )
    }
}

private enum InitialCommandKind: String, CaseIterable, Identifiable {
    case shell, claude, claudeContinue, claudeResume, custom

    var id: String { rawValue }

    init(_ command: InitialCommand) {
        switch command {
        case .shell: self = .shell
        case .claude: self = .claude
        case .claudeContinue: self = .claudeContinue
        case .claudeResume: self = .claudeResume
        case .custom: self = .custom
        }
    }

    func makeCommand() -> InitialCommand {
        switch self {
        case .shell: return .shell
        case .claude: return .claude
        case .claudeContinue: return .claudeContinue
        case .claudeResume: return .claudeResume
        case .custom: return .custom("")
        }
    }

    var label: String {
        switch self {
        case .shell: return "shell seul"
        case .claude: return "claude"
        case .claudeContinue: return "claude --continue"
        case .claudeResume: return "claude --resume"
        case .custom: return "commande personnalisée…"
        }
    }
}

// MARK: - Éléments partagés

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.latchTextDim)
            .textCase(nil)
    }
}

private struct Field: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    init(_ label: String, placeholder: String, text: Binding<String>) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextFaint)
                .frame(width: 90, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color.latchText)
        }
    }
}

/// Une carte d'étape du §9.2.
private struct StepCard<Content: View>: View {
    let badge: String
    let isDeletable: Bool
    /// Une carte dépliable ; `nil` pour une carte toujours ouverte.
    var isExpanded: Binding<Bool>?
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    init(
        badge: String,
        isDeletable: Bool,
        isExpanded: Binding<Bool>? = nil,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.badge = badge
        self.isDeletable = isDeletable
        self.isExpanded = isExpanded
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let isExpanded {
                        Button {
                            isExpanded.wrappedValue.toggle()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.latchTextFaint)
                                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        }
                        .buttonStyle(.plain)
                    }

                    Text(badge)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.latchTextFaint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.latchSurfaceHigh))

                    Spacer()

                    // Pas d'icône corbeille sur la connexion : elle n'est pas
                    // supprimable, et le dire par l'absence vaut mieux qu'un
                    // bouton grisé.
                    if isDeletable {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.latchTextFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isExpanded?.wrappedValue ?? true {
                    content
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.latchSurface))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 20))
    }
}

private struct AddRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .moveDisabled(true)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 8, trailing: 20))
    }
}
