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

import AppKit
import SwiftUI

struct BuilderView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var shortcut: Shortcut
    @State private var previewText: String = ""
    /// Le dernier texte que l'app a écrit dans l'aperçu. C'est lui qui permet
    /// de reconnaître une frappe de l'utilisateur ; un drapeau ne le pourrait
    /// pas, `onChange` arrivant au tour de boucle suivant.
    @State private var lastGeneratedPreview = ""
    @State private var isConnectionExpanded = true
    /// Le champ à activer après un ajout : on vient de cliquer « Ajouter », on
    /// veut taper, pas chercher où.
    @FocusState private var focused: UUID?

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
                StepCard(badge: "local", isDeletable: true, isReorderable: true) {
                    app.errorMessage = nil
                    shortcut.preflight.removeAll { $0.id == step.id }
                } content: {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("VPN", text: $step.label)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .focused($focused, equals: step.id)
                        TextField("scutil --nc status Maison", text: $step.command)
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
                // Créé **vide** : un nom par défaut masque l'exemple et fait
                // passer le champ pour une étiquette. Le curseur y va tout seul.
                let step = Preflight(label: "", command: "")
                shortcut.preflight.append(step)
                // La ligne n'existe pas encore à cet instant : viser le champ
                // avant qu'il soit là ne fait rien.
                DispatchQueue.main.async { focused = step.id }
            }
        } header: {
            OptionalSectionHeader(
                title: "Pré-vol",
                isUsed: !shortcut.preflight.isEmpty,
                explanation: "Des commandes lancées **sur le Mac**, avant de se "
                    + "connecter : monter un VPN, démarrer un tunnel, réveiller une "
                    + "machine. Une étape fatale qui échoue annule la connexion ; "
                    + "les autres avertissent et laissent passer."
            )
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
                StepCard(badge: "tmux", isDeletable: true, isReorderable: true) {
                    shortcut.windows.removeAll { $0.id == window.id }
                } content: {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("logs", text: $window.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .focused($focused, equals: window.id)
                        TextField("journalctl -fu api", text: $window.command)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.latchTextDim)
                        Text("Un nom que tu reconnaîtras, et ce qui tourne dedans.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.latchTextFaint)
                    }
                }
            }
            .onMove { source, destination in
                shortcut.windows.move(fromOffsets: source, toOffset: destination)
            }

            AddRow(title: "Ajouter une fenêtre") {
                let window = TmuxWindow(name: "", command: "")
                shortcut.windows.append(window)
                DispatchQueue.main.async { focused = window.id }
            }
        } header: {
            OptionalSectionHeader(
                title: "Fenêtres",
                isUsed: !shortcut.windows.isEmpty,
                explanation: "Des onglets **à l'intérieur** de la session "
                    + "distante : ton éditeur dans l'une, les journaux qui défilent "
                    + "dans une autre. Elles vivent sur le serveur, survivent à la "
                    + "déconnexion, et se choisissent depuis la barre latérale.\n\n"
                    + "À chaque connexion, celles qui manquent sont créées ; les "
                    + "autres sont laissées telles quelles, et aucune n'est jamais "
                    + "fermée. La plupart des sessions n'en ont pas besoin — tmux "
                    + "sait très bien en ouvrir à la main."
            )
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

    /// L'aperçu ne contient **jamais** autre chose qu'une commande. Y écrire
    /// les erreurs de validation les faisait adopter comme commande
    /// personnalisée à la frappe suivante — et « Il manque l'hôte de rebond. »
    /// donne un shell qui refuse de démarrer sur une apostrophe non fermée.
    /// Les erreurs s'affichent en dessous.
    private func refreshPreview() {
        let generated = (try? CommandBuilder.build(shortcut)) ?? ""
        lastGeneratedPreview = generated
        previewText = generated
    }

    /// Si l'utilisateur modifie l'aperçu, le raccourci bascule en mode
    /// personnalisé — mais retaper exactement la commande générée ne doit pas
    /// le faire basculer pour rien.
    private func adoptEditedPreview(_ text: String) {
        switch PreviewEdit.decide(edited: text, lastGenerated: lastGeneratedPreview) {
        case .ignore:
            break
        case .revert:
            shortcut.customCommand = nil
        case .adopt(let command):
            shortcut.customCommand = command
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
                Field(
                    "Hôte",
                    placeholder: "alex@192.168.1.10 ou un alias ~/.ssh/config",
                    text: $connection.host
                )
                ResolvedHost(alias: connection.host)

                Field(
                    "Port",
                    placeholder: "22",
                    text: Binding(
                        get: { connection.port.map(String.init) ?? "" },
                        set: { connection.port = Int($0.filter(\.isNumber)) }
                    )
                )

                Field(
                    "Clé",
                    placeholder: "clés par défaut du Mac",
                    text: Binding(
                        get: { connection.identityFile ?? "" },
                        set: { connection.identityFile = $0.isEmpty ? nil : $0 }
                    )
                )
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

/// Où mène réellement l'alias.
///
/// Le champ « Hôte » contient un alias, pas une adresse : c'est `~/.ssh/config`
/// qui décide où il pointe, et Latch ne possède pas ce fichier. Ne rien
/// afficher laissait l'utilisateur sans aucun moyen de savoir d'où sortait
/// l'adresse, ni où la changer — alors que le §14 prévient qu'elle bouge.
private struct ResolvedHost: View {
    let alias: String

    @State private var target: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Spacer().frame(width: 90)

            if let target {
                Text(target)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.latchTextFaint)
                    .textSelection(.enabled)
                    .lineLimit(1)

                Button("~/.ssh/config") {
                    NSWorkspace.shared.selectFile(
                        SSHConfig.defaultURL.path,
                        inFileViewerRootedAtPath: SSHConfig.defaultURL.deletingLastPathComponent().path
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.latchAccent)
                .help("Ouvrir le fichier qui décide où pointe cet alias")
            }
            Spacer(minLength: 0)
        }
        .task(id: alias) {
            target = Self.resolve(alias)
        }
    }

    /// `ssh -G` applique tout le fichier — `HostName`, `User`, `Port`, `Match`,
    /// les inclusions — et rend ce que ssh utiliserait vraiment.
    private static func resolve(_ alias: String) -> String? {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let hostName = SSHConfig.effectiveValue("hostname", for: trimmed) else { return nil }

        let user = SSHConfig.effectiveValue("user", for: trimmed)
        let port = SSHConfig.effectiveValue("port", for: trimmed) ?? "22"

        var description = hostName
        if let user { description = "\(user)@\(description)" }
        if port != "22" { description += ":\(port)" }
        // Une adresse tapée directement se résout en elle-même : ce n'est pas
        // une configuration, c'est ce qu'on a écrit. On le dit quand même, avec
        // la clé que ssh choisira — c'est toute la question que pose le champ.
        if hostName == trimmed || "\(user ?? "")@\(hostName)" == trimmed {
            return description + " · " + localized("clés par défaut du Mac")
        }
        return description + " · ~/.ssh/config"
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
        case .shell: return localized("shell seul")
        case .claude: return "claude"
        case .claudeContinue: return "claude --continue"
        case .claudeResume: return "claude --resume"
        case .custom: return localized("commande personnalisée…")
        }
    }
}

// MARK: - Éléments partagés

/// L'en-tête d'une section facultative.
///
/// Tant qu'elle ne sert pas, elle se réduit à son titre : une explication qu'on
/// traverse à chaque fois pour n'en avoir jamais besoin est un coût payé par
/// tout le monde au profit de quelques-uns. Elle apparaît dès qu'on s'en sert,
/// et se déplie à la demande.
private struct OptionalSectionHeader: View {
    let title: String
    let isUsed: Bool
    let explanation: String

    @State private var isExplaining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SectionTitle(title)
                Button {
                    isExplaining.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.latchTextFaint)
                }
                .buttonStyle(.plain)
                .help(localized("À quoi ça sert ?"))
                Spacer(minLength: 0)
            }

            if isExplaining || isUsed {
                Text(.init(localized(explanation)))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.latchTextFaint)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = localized(title) }

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
    /// La carte se réordonne-t-elle ? La connexion, non : elle est seule.
    let isReorderable: Bool
    /// Une carte dépliable ; `nil` pour une carte toujours ouverte.
    var isExpanded: Binding<Bool>?
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    init(
        badge: String,
        isDeletable: Bool,
        isReorderable: Bool = false,
        isExpanded: Binding<Bool>? = nil,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.badge = badge
        self.isDeletable = isDeletable
        self.isReorderable = isReorderable
        self.isExpanded = isExpanded
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Le corps de la carte est fait de champs de texte, qui avalent le
            // glissement : sans gouttière, la prise se réduit à la marge et
            // rien ne l'indique. Cette colonne est vide de contrôles sur toute
            // la hauteur, et le trait dit où saisir.
            if isReorderable {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.latchTextFaint)
                    .frame(width: 12, alignment: .center)
                    .padding(.top, 3)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .help(localized("Glisser pour réordonner"))
            }

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
