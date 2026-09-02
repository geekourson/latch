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
    /// Le serveur dont le panneau d'amélioration est ouvert (§6).
    @Published var upgradingServerID: Server.ID?
    /// Erreur de validation ou d'ouverture, affichée sans bloquer.
    @Published var errorMessage: String?

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

        let probe = store.probe(forHost: shortcut.connection.host)
        let degradation = ServerCapabilities.degradation(for: shortcut, probe: probe)

        // Le driver du §3.2 construit la commande et, pour mosh, fait sa
        // poignée de main avant de la rendre.
        let driver = ConnectionDrivers.driver(for: shortcut, degradation: degradation)
        do {
            let plan = try await driver.plan(for: shortcut, degradation: degradation)
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
        } catch {
            errorMessage = error.localizedDescription
        }
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

    // MARK: - Fermeture

    func close(tabID: TerminalSession.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)

        if selectedTabID == tabID {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func closeAll() {
        tabs.forEach { $0.terminate() }
        tabs.removeAll()
        selectedTabID = nil
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
