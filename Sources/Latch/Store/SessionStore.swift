//
//  SessionStore.swift
//  Latch
//
//  Persistance (SPEC §4) : un fichier JSON dans
//  `~/Library/Application Support/app.latch.Latch/shortcuts.json`.
//
//  **Aucun secret dans ce fichier.** L'authentification se fait par clé ; si un
//  mot de passe devient indispensable un jour, il ira dans le trousseau et
//  nulle part ailleurs (§11).
//

import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {

    @Published var servers: [Server] = []
    @Published var shortcuts: [Shortcut] = []
    /// Thèmes importés (§9.3). La palette « braise » n'est pas dedans : elle
    /// est intégrée et ne se supprime pas.
    @Published var themes: [Theme] = []
    @Published var preferences = Preferences()

    /// Dernière erreur d'écriture, affichée par l'interface plutôt qu'avalée.
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var isLoading = false

    // MARK: - Emplacement

    nonisolated static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.latch.Latch", isDirectory: true)
    }

    nonisolated static var defaultFileURL: URL {
        defaultDirectory.appendingPathComponent("shortcuts.json")
    }

    // MARK: - Format du fichier

    /// Enveloppe versionnée : le jour où le modèle bouge, on saura de quoi on
    /// part. Serveurs et raccourcis restent deux listes distinctes (§4), dans
    /// un seul fichier écrit d'un bloc.
    private struct Document: Codable {
        var version: Int = 1
        var servers: [Server] = []
        var shortcuts: [Shortcut] = []
        var themes: [Theme] = []
        var preferences = Preferences()

        enum CodingKeys: String, CodingKey {
            case version, servers, shortcuts, themes, preferences
        }

        init(
            version: Int = 1,
            servers: [Server] = [],
            shortcuts: [Shortcut] = [],
            themes: [Theme] = [],
            preferences: Preferences = Preferences()
        ) {
            self.version = version
            self.servers = servers
            self.shortcuts = shortcuts
            self.themes = themes
            self.preferences = preferences
        }

        /// Combien d'entrées ont été écartées parce qu'illisibles.
        var skippedEntries = 0

        /// Tolérant aux absences : une version antérieure de Latch n'écrivait
        /// ni thèmes ni réglages, et son fichier doit rester lisible. Une
        /// entrée cassée est écartée seule, pas avec toute la liste.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = container.value(.version, or: 1)
            preferences = container.value(.preferences, or: Preferences())

            let servers = container.lenient(.servers, of: Server.self)
            let shortcuts = container.lenient(.shortcuts, of: Shortcut.self)
            let themes = container.lenient(.themes, of: Theme.self)

            self.servers = servers.values
            self.shortcuts = shortcuts.values
            self.themes = themes.values
            skippedEntries = servers.skipped + shortcuts.skipped + themes.skipped
        }
    }

    // MARK: - Cycle de vie

    init(fileURL: URL = SessionStore.defaultFileURL, seedFromSSHConfig: Bool = true) {
        self.fileURL = fileURL
        load(seedFromSSHConfig: seedFromSSHConfig)
    }

    func load(seedFromSSHConfig: Bool = true) {
        isLoading = true
        defer { isLoading = false }

        guard let data = try? Data(contentsOf: fileURL) else {
            if seedFromSSHConfig { seedServersFromSSHConfig() }
            return
        }

        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            servers = document.servers
            shortcuts = document.shortcuts
            themes = document.themes
            preferences = document.preferences

            // Ce qu'on a dû écarter se dit : disparaître en silence serait pire
            // que de refuser le fichier.
            if document.skippedEntries > 0 {
                lastError = "\(document.skippedEntries) entrée(s) illisible(s) ont été ignorées. "
                    + "Le fichier n'a pas encore été réécrit : \(fileURL.path)"
            }
        } catch {
            // Un fichier illisible ne doit pas empêcher l'app de démarrer, et
            // surtout pas être écrasé en silence : on le laisse en place et on
            // le dit.
            lastError = "Configuration illisible (\(error.localizedDescription)). "
                + "Le fichier n'a pas été modifié : \(fileURL.path)"
        }
    }

    /// Au premier lancement, la barre latérale se remplit avec les hôtes déjà
    /// déclarés dans `~/.ssh/config`. Aucun raccourci n'est inventé.
    private func seedServersFromSSHConfig() {
        servers = SSHConfig.hosts().map { Server(name: $0, sshAlias: $0) }
        guard !servers.isEmpty else { return }
        scheduleSave()
    }

    // MARK: - Écriture

    /// Regroupe les écritures : l'écran du builder modifie le modèle à chaque
    /// frappe, on n'écrit pas le disque à chaque caractère.
    func scheduleSave(after delay: Duration = .milliseconds(400)) {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let document = Document(
            version: 1,
            servers: servers,
            shortcuts: shortcuts,
            themes: themes,
            preferences: preferences
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Écriture atomique : une coupure de courant ne doit pas laisser
            // un fichier de configuration tronqué.
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Échec de l'enregistrement : \(error.localizedDescription)"
        }
    }

    // MARK: - Raccourcis

    func add(_ shortcut: Shortcut) {
        shortcuts.append(shortcut)
        scheduleSave()
    }

    func update(_ shortcut: Shortcut) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index] = shortcut
        scheduleSave()
    }

    func remove(shortcutID: Shortcut.ID) {
        shortcuts.removeAll { $0.id == shortcutID }
        scheduleSave()
    }

    func shortcut(id: Shortcut.ID) -> Shortcut? {
        shortcuts.first { $0.id == id }
    }

    // MARK: - Serveurs

    /// Le serveur qui porte cet alias, créé au besoin : un raccourci ne doit
    /// jamais pointer vers un hôte que la barre latérale ignore.
    @discardableResult
    func server(forAlias alias: String, creatingIfNeeded: Bool = false) -> Server? {
        if let existing = servers.first(where: { $0.sshAlias == alias }) { return existing }
        guard creatingIfNeeded, !alias.isEmpty else { return nil }
        let created = Server(name: alias, sshAlias: alias)
        servers.append(created)
        scheduleSave()
        return created
    }

    func update(_ server: Server) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        scheduleSave()
    }

    func remove(serverID: Server.ID) {
        servers.removeAll { $0.id == serverID }
        scheduleSave()
    }

    /// Les raccourcis attachés à un serveur, dans l'ordre où ils sont rangés.
    func shortcuts(for server: Server) -> [Shortcut] {
        shortcuts.filter { $0.connection.host == server.sshAlias }
    }

    /// Les raccourcis qui ne se rattachent à aucun serveur connu — les locaux,
    /// et ceux dont l'alias a été tapé à la main.
    var unattachedShortcuts: [Shortcut] {
        let aliases = Set(servers.map(\.sshAlias))
        return shortcuts.filter {
            $0.connection.transport == .local || !aliases.contains($0.connection.host)
        }
    }

    // MARK: - Thèmes (§9.3)

    /// Change la langue de l'interface et l'applique aussitôt (§9.3 étendu).
    func setLanguage(_ language: Language) {
        guard preferences.language != language else { return }
        preferences.language = language
        Localization.apply(language)
        scheduleSave()
    }

    /// Le thème actif, ou la palette « braise » si aucun n'a été choisi.
    var activeTheme: Theme {
        themes.first { $0.id == preferences.themeID } ?? .ember
    }

    /// Ce que la vue de terminal doit appliquer, dérivé des réglages.
    var terminalStyle: TerminalStyle {
        TerminalStyle(
            theme: activeTheme,
            fontName: preferences.fontName,
            fontSize: CGFloat(preferences.fontSize),
            lineSpacing: CGFloat(preferences.lineSpacing),
            padding: CGFloat(preferences.padding)
        )
    }

    /// Importe un `.itermcolors` ou un schéma base16 et l'active.
    @discardableResult
    func importTheme(at url: URL) throws -> Theme {
        var theme = try ThemeImporter.theme(contentsOf: url)

        // Réimporter le même fichier remplace le thème plutôt que d'en empiler
        // un doublon dans le sélecteur — en gardant l'identifiant existant,
        // pour que le raccourci qui le désignait continue de le désigner.
        if let index = themes.firstIndex(where: {
            $0.name == theme.name && $0.source == theme.source
        }) {
            theme.id = themes[index].id
            themes[index] = theme
        } else {
            themes.append(theme)
        }

        preferences.themeID = theme.id
        scheduleSave()
        return theme
    }

    func removeTheme(id: Theme.ID) {
        themes.removeAll { $0.id == id }
        if preferences.themeID == id { preferences.themeID = nil }
        scheduleSave()
    }

    // MARK: - Sonde (§6)

    /// Interroge l'hôte et met le résultat en cache. Ne relance rien si la
    /// sonde est encore fraîche, sauf demande explicite.
    func probe(serverID: Server.ID, force: Bool = false) async {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        let server = servers[index]
        guard force || server.probeIsStale else { return }

        let result = try? await ServerProbe.probe(alias: server.sshAlias)
        guard let currentIndex = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[currentIndex].probe = result
        servers[currentIndex].probedAt = result == nil ? nil : Date()
        scheduleSave()
    }

    /// Invalide le cache d'un hôte, pour que le bandeau disparaisse tout seul
    /// si l'installation a réussi — et reste s'il a échoué (§6).
    func invalidateProbe(serverID: Server.ID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].probe = nil
        servers[index].probedAt = nil
        scheduleSave()
    }

    func probe(forHost alias: String) -> ProbeResult? {
        servers.first { $0.sshAlias == alias }?.probe
    }
}
