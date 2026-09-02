//
//  AppState.swift
//  Latch
//
//  L'état d'exécution : les onglets ouverts, la sélection, les panneaux. Ce qui
//  se persiste vit dans `SessionStore` ; ce qui meurt avec la fenêtre vit ici.
//

import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {

    let store: SessionStore

    @Published private(set) var tabs: [TerminalSession] = []
    @Published var selectedTabID: TerminalSession.ID?

    /// Le raccourci en cours d'édition dans l'écran du builder (§9.2).
    @Published var editedShortcut: Shortcut?
    /// L'hôte dont le panneau d'amélioration est ouvert (§6) — un serveur, ou
    /// le Mac lui-même pour les raccourcis locaux.
    @Published var upgradingTarget: UpgradeTarget?
    /// Erreur de validation ou d'ouverture, affichée sans bloquer.
    @Published var errorMessage: String?

    /// Ce que les hooks du §10 racontent, par hôte.
    @Published private(set) var claudeActivity: [String: ClaudeActivity] = [:]

    /// Une connexion ssh secondaire par hôte ayant un onglet ouvert.
    private var hookStreams: [String: HookStream] = [:]

    /// Les vraies fenêtres tmux, par hôte (§12, v0.4).
    @Published private(set) var liveWindows: [String: [String: [LiveWindow]]] = [:]
    private var inspectors: [String: TmuxInspector] = [:]

    /// Le serveur MCP qui expose Latch à Claude Code (§10).
    let mcp = MCPServer()

    private var cancellables = Set<AnyCancellable>()

    /// Le store est construit ici et pas dans la valeur par défaut du
    /// paramètre : une expression par défaut s'évalue dans l'isolement de
    /// l'appelant, et `SessionStore` est lié à l'acteur principal.
    init(store: SessionStore? = nil) {
        let store = store ?? SessionStore()
        self.store = store
        // Le store est une source de vérité imbriquée : sans ça, SwiftUI ne
        // redessine pas la barre latérale quand un raccourci change.
        store.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        observeSystemSleep()

        mcp.host = self
        mcp.start()
    }

    // MARK: - Veille et réveil (§8)

    /// La SPEC cite `NSWorkspace.didSleepNotification`, qui n'existe pas :
    /// AppKit expose `willSleepNotification` avant l'endormissement et
    /// `didWakeNotification` au retour. C'est ce couple qu'on écoute.
    private func observeSystemSleep() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnectAll() }
        }
    }

    /// On marque, on ne tue rien : avec mosh, la session traverse la veille
    /// sans qu'on ait à toucher à quoi que ce soit.
    func systemWillSleep() {
        tabs.forEach { $0.systemWillSleep() }
    }

    /// Au réveil, chaque onglet regarde si son process a survécu. S'il est
    /// vivant, rien à faire ; sinon il relance exactement la même commande.
    func reconnectAll() {
        tabs.forEach { $0.systemDidWake() }
    }

    var selectedTab: TerminalSession? {
        tabs.first { $0.id == selectedTabID }
    }

    // MARK: - Ouverture

    /// Ouvre un raccourci, ou remet au premier plan l'onglet qui l'affiche déjà.
    ///
    /// La sonde du §6 tourne d'abord si elle est absente ou périmée : c'est le
    /// seul moyen de savoir s'il faut dégrader la commande. Elle ne bloque rien
    /// d'autre — un seul aller-retour, et un échec se traite comme « serveur
    /// complet » plutôt que d'empêcher la connexion.
    func open(_ shortcut: Shortcut) async {
        if let existing = tabs.first(where: { $0.shortcutID == shortcut.id }) {
            selectedTabID = existing.id
            return
        }

        if shortcut.connection.transport.isRemote,
           let server = store.server(forAlias: shortcut.connection.host) {
            await store.probe(serverID: server.id)
        }

        // Le Mac est un hôte comme un autre : un raccourci local mérite la même
        // sonde, et la même cascade s'il manque tmux.
        let probe = shortcut.connection.transport.isRemote
            ? store.probe(forHost: shortcut.connection.host)
            : LocalTools.probe()
        let degradation = ServerCapabilities.degradation(for: shortcut, probe: probe)

        // Le driver du §3.2 construit la commande et, pour mosh, fait sa
        // poignée de main avant de la rendre.
        let driver = ConnectionDrivers.driver(for: shortcut, degradation: degradation)
        do {
            let plan = try await driver.plan(
                for: shortcut,
                degradation: degradation,
                toolPaths: probe?.offPathTools ?? [:]
            )
            let session = TerminalSession(
                name: shortcut.name,
                command: plan.command,
                shortcutID: shortcut.id,
                host: shortcut.connection.host,
                degradation: degradation,
                environment: plan.environment,
                notice: plan.notice
            )
            tabs.append(session)
            selectedTabID = session.id
            followHooks(on: shortcut.connection.host)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Hooks Claude Code (§10)

    /// Ouvre — au plus une fois par hôte — la connexion secondaire qui suit le
    /// journal d'événements. Elle échoue en silence si les hooks ne sont pas
    /// installés : le fichier est simplement vide.
    private func followHooks(on host: String) {
        guard !host.isEmpty, hookStreams[host] == nil else { return }

        let stream = HookStream(
            alias: host,
            remoteForward: mcp.isRunning ? mcp.remoteForwardOption : nil
        )
        stream.onEvent = { [weak self, weak stream] event in
            guard let self, let stream else { return }
            self.claudeActivity[host] = stream.activity
            self.announce(event, on: host)
        }
        hookStreams[host] = stream
        stream.start()

        let inspector = TmuxInspector(alias: host)
        inspectors[host] = inspector
        inspector.objectWillChange
            .sink { [weak self, weak inspector] in
                // `objectWillChange` précède la mutation : on relit au tour
                // suivant, sinon on recopie l'ancienne valeur.
                DispatchQueue.main.async {
                    guard let self, let inspector else { return }
                    self.liveWindows[host] = inspector.windows
                }
            }
            .store(in: &cancellables)
        inspector.start()
    }

    /// Le §10 demande une notification quand une tâche se termine ou qu'une
    /// permission est attendue — et rien d'autre. Chaque outil utilisé ne
    /// mérite pas d'interrompre qui que ce soit.
    private func announce(_ event: HookEvent, on host: String) {
        if event.isAwaitingPermission {
            Notifier.notifyAwaitingPermission(host: host)
        } else if event.kind == .stop {
            Notifier.notifyTaskFinished(host: host)
        }
    }

    /// Coupe les flux des hôtes qui n'ont plus d'onglet : une connexion ssh
    /// qui ne sert plus à rien n'a pas à rester ouverte.
    private func pruneHookStreams() {
        let liveHosts = Set(tabs.map(\.host))
        for (host, stream) in hookStreams where !liveHosts.contains(host) {
            stream.stop()
            hookStreams.removeValue(forKey: host)
            claudeActivity.removeValue(forKey: host)
        }
        for (host, inspector) in inspectors where !liveHosts.contains(host) {
            inspector.stop()
            inspectors.removeValue(forKey: host)
            liveWindows.removeValue(forKey: host)
        }
    }

    /// Les fenêtres tmux d'une session ouverte sur un hôte.
    func liveWindows(on host: String, session: String) -> [LiveWindow] {
        (liveWindows[host]?[session] ?? []).sorted { $0.index < $1.index }
    }

    /// Bascule la session distante sur cette fenêtre. Le terminal suit tout
    /// seul : c'est tmux qui décide de ce qu'il affiche.
    func select(_ window: LiveWindow, on host: String) {
        inspectors[host]?.select(window)
    }

    /// Installe les hooks sur un hôte, puis rouvre le flux pour que
    /// l'indicateur s'allume sans attendre une reconnexion.
    func installHooks(on alias: String) async -> Result<String, Error> {
        do {
            let output = try await HookInstaller.install(on: alias)
            hookStreams[alias]?.stop()
            hookStreams.removeValue(forKey: alias)
            followHooks(on: alias)
            return .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(error)
        }
    }

    func claudeActivity(on host: String) -> ClaudeActivity? {
        guard let activity = claudeActivity[host], activity.isActive else { return nil }
        return activity
    }

    /// Ouvre un terminal sur un hôte sans passer par un raccourci — ce que fait
    /// le bouton « Exécuter dans un panneau » du panneau d'amélioration (§6).
    @discardableResult
    func openBareShell(on alias: String, named name: String) -> TerminalSession {
        let session = TerminalSession(
            name: name,
            command: "ssh -t \(ShellQuoting.quoted(alias))",
            host: alias
        )
        tabs.append(session)
        selectedTabID = session.id
        return session
    }

    /// Le même panneau, mais sur le Mac : une session locale s'installe ses
    /// outils localement.
    @discardableResult
    func openLocalShell(named name: String) -> TerminalSession {
        let session = TerminalSession(name: name, command: "exec $SHELL -l")
        tabs.append(session)
        selectedTabID = session.id
        return session
    }

    // MARK: - Fermeture

    func close(tabID: TerminalSession.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)

        if selectedTabID == tabID {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        pruneHookStreams()
    }

    func closeAll() {
        tabs.forEach { $0.terminate() }
        tabs.removeAll()
        selectedTabID = nil
        pruneHookStreams()
    }

    // MARK: - État des serveurs (§9.1)

    enum ServerStatus {
        /// Vert : au moins un onglet vivant, sans dégradation.
        case connected
        /// Ambre : connecté mais dégradé, ou une sonde qui annonce du manque.
        case degraded
        /// Gris : rien d'ouvert.
        case offline
    }

    func status(of server: Server) -> ServerStatus {
        let live = tabs.filter { $0.host == server.sshAlias && $0.isRunning }
        if live.contains(where: { $0.degradation == .none }) { return .connected }
        if !live.isEmpty { return .degraded }
        if ServerCapabilities.degradation(for: server.probe).isDegraded { return .degraded }
        return .offline
    }

    /// La dégradation à annoncer pour l'onglet courant, s'il y en a une.
    var currentDegradation: Degradation {
        selectedTab?.degradation ?? .none
    }

    var currentServer: Server? {
        guard let host = selectedTab?.host else { return nil }
        return store.servers.first { $0.sshAlias == host }
    }

    /// L'hôte que le bandeau propose d'améliorer : le serveur de l'onglet
    /// courant, ou le Mac si cet onglet est local.
    var currentTarget: UpgradeTarget? {
        guard let session = selectedTab else { return nil }
        if session.host.isEmpty { return .localMac }
        return currentServer.map { .server($0) }
    }

    // MARK: - Édition

    func newShortcut(host: String = "") {
        editedShortcut = Shortcut(
            name: "Nouvelle session",
            connection: Connection(
                transport: host.isEmpty ? .local : .mosh,
                host: host,
                tmuxSession: "session"
            )
        )
    }

    func save(_ shortcut: Shortcut) {
        if store.shortcut(id: shortcut.id) == nil {
            store.add(shortcut)
        } else {
            store.update(shortcut)
        }
        if shortcut.connection.transport.isRemote {
            store.server(forAlias: shortcut.connection.host, creatingIfNeeded: true)
        }
        editedShortcut = nil
    }
}

// MARK: - Serveur MCP (§10)

/// Ce que Latch accepte de faire pour Claude Code. Rien qui touche au système :
/// seulement ouvrir des onglets dans l'app, ce que l'utilisateur voit et peut
/// fermer. Les commandes proposées passent par les mêmes chemins que celles
/// tapées à la main, échappement compris.
extension AppState: MCPHost {

    func mcpListSessions() -> [[String: Any]] {
        tabs.map { session in
            [
                "name": session.name,
                "title": session.title,
                "host": session.host,
                "state": session.connection.label,
                "selected": session.id == selectedTabID,
            ]
        }
    }

    func mcpOpenSession(named name: String) async -> String {
        let wanted = name.lowercased()
        guard
            let shortcut = store.shortcuts.first(where: { $0.name.lowercased() == wanted })
                ?? store.shortcuts.first(where: {
                    $0.connection.tmuxSession.lowercased() == wanted
                })
        else {
            let known = store.shortcuts.map(\.name).joined(separator: ", ")
            return "Aucun raccourci nommé « \(name) ». Raccourcis connus : \(known)."
        }
        await open(shortcut)
        return "Onglet « \(shortcut.name) » ouvert."
    }

    func mcpRunCommand(_ command: String, on host: String?, named name: String?) -> String {
        guard let alias = host ?? selectedTab?.host, !alias.isEmpty else {
            return "Aucun hôte : précise « host », ou ouvre d'abord une session."
        }
        let title = name ?? command
        let session = TerminalSession(
            name: title,
            command: "ssh -t \(ShellQuoting.quoted(alias)) \(ShellQuoting.doubleQuoted(command))",
            host: alias
        )
        tabs.append(session)
        selectedTabID = session.id
        return "Onglet « \(title) » ouvert sur \(alias)."
    }

    func mcpShowFile(_ path: String, on host: String?) -> String {
        guard let alias = host ?? selectedTab?.host, !alias.isEmpty else {
            return "Aucun hôte : précise « host », ou ouvre d'abord une session."
        }
        // `less -R` garde les couleurs et rend la main avec « q ». Le fichier
        // est seulement lu ; Latch n'écrit jamais dedans.
        let remote = "less -R -- \(ShellQuoting.quoted(path))"
        let session = TerminalSession(
            name: (path as NSString).lastPathComponent,
            command: "ssh -t \(ShellQuoting.quoted(alias)) \(ShellQuoting.doubleQuoted(remote))",
            host: alias
        )
        tabs.append(session)
        selectedTabID = session.id
        return "« \(path) » affiché depuis \(alias)."
    }
}
