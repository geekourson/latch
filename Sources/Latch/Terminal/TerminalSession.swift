//
//  TerminalSession.swift
//  Latch
//
//  Un onglet : une commande, un pseudo-terminal, et le cycle de vie du §8.
//  La commande vient du `CommandBuilder` ; cette classe ne sait pas la
//  construire et ne cherche jamais à l'interpréter.
//

import Combine
import Foundation

@MainActor
final class TerminalSession: ObservableObject, Identifiable {

    nonisolated let id = UUID()

    // MARK: État publié

    /// Titre annoncé par le terminal distant (séquence OSC 0/2).
    @Published private(set) var title: String
    /// L'état que lit l'interface (§3.2).
    @Published private(set) var connection: ConnectionState = .idle
    /// Dernière taille annoncée par la vue.
    @Published private(set) var size: (rows: Int, cols: Int) = (0, 0)
    /// Code de sortie du dernier process, pour la barre d'état.
    @Published private(set) var lastExitCode: Int32?

    // MARK: Identité

    let name: String
    /// La commande exécutée localement via `/bin/sh -c`.
    let command: String
    let shortcutID: Shortcut.ID?
    /// L'alias de l'hôte, pour la pastille d'état de la barre latérale.
    let host: String
    /// Ce que la sonde a imposé de perdre en route (§6).
    let degradation: Degradation
    /// Variables ajoutées à l'environnement du process. C'est par là que passe
    /// la clé de session mosh : jamais par la ligne de commande, où n'importe
    /// quel `ps` la lirait.
    let environment: [String: String]
    /// Remarque du driver, affichée discrètement (transport de repli, etc.).
    let notice: String?

    var policy = ReconnectionPolicy()

    /// Fourni par l'app quand un mot de passe est enregistré au trousseau
    /// (§11). Il n'est lu qu'au moment de répondre à une invite, et n'est
    /// jamais conservé par la session.
    var passwordProvider: (() -> String?)?

    // MARK: Interne

    private var pty = PTYProcess()
    private var ptyBindings = Set<AnyCancellable>()
    private let outputSubject = PassthroughSubject<Data, Never>()

    private var lastGeometry: (rows: UInt16, cols: UInt16) = (24, 80)
    private var promptDetector = PasswordPromptDetector()
    private var launchedAt: Date?
    private var connectedAt: Date?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    /// Vrai quand la fermeture vient de l'utilisateur : on ne relance rien.
    private var isClosing = false
    /// Vrai entre l'endormissement et le réveil.
    private var isSuspended = false

    /// Octets reçus du process. Le sujet appartient à la session et non au PTY :
    /// une reconnexion remplace le PTY, et la vue ne doit pas perdre son
    /// abonnement au passage.
    var output: AnyPublisher<Data, Never> { outputSubject.eraseToAnyPublisher() }

    var isRunning: Bool { connection.isLive }

    // MARK: - Cycle de vie

    init(
        name: String,
        command: String,
        shortcutID: Shortcut.ID? = nil,
        host: String = "",
        degradation: Degradation = .none,
        environment: [String: String] = [:],
        notice: String? = nil
    ) {
        self.name = name
        self.command = command
        self.shortcutID = shortcutID
        self.host = host
        self.degradation = degradation
        self.environment = environment
        self.notice = notice
        self.title = name
        bind(pty)
    }

    /// Démarre le process. Appelé par la vue une fois qu'elle connaît sa taille,
    /// pour que le premier `winsize` soit déjà le bon.
    func start(rows: UInt16, cols: UInt16) {
        lastGeometry = (rows, cols)
        guard connection == .idle else { return }
        launch()
    }

    /// SPEC §11 : le mot de passe part **sur le PTY**, après détection de
    /// l'invite, jamais en argument de commande. Il n'est ni journalisé ni
    /// gardé : on le demande, on l'écrit, on l'oublie.
    private func answerPasswordPromptIfNeeded(_ data: Data) {
        guard let passwordProvider, let launchedAt else { return }
        let elapsed = Date().timeIntervalSince(launchedAt)
        guard promptDetector.shouldAnswer(after: String(decoding: data, as: UTF8.self),
                                          elapsed: elapsed)
        else { return }
        guard let password = passwordProvider() else { return }
        pty.send(Data((password + "\n").utf8))
    }

    private func launch() {
        launchedAt = Date()
        connection = .connecting
        do {
            try pty.start(
                command: command,
                rows: lastGeometry.rows,
                cols: lastGeometry.cols,
                environment: mergedEnvironment
            )
        } catch {
            connection = .failed(reason: error.localizedDescription)
        }
    }

    /// L'environnement du process, augmenté de celui du driver.
    private var mergedEnvironment: [String: String] {
        guard !environment.isEmpty else { return ProcessInfo.processInfo.environment }
        return ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }

    private func bind(_ pty: PTYProcess) {
        ptyBindings.removeAll()
        pty.output
            .sink { [weak self] data in
                self?.outputSubject.send(data)
                self?.answerPasswordPromptIfNeeded(data)
            }
            .store(in: &ptyBindings)
        pty.state
            .sink { [weak self] in self?.handle($0) }
            .store(in: &ptyBindings)
    }

    private func handle(_ state: PTYState) {
        switch state {
        case .idle:
            break

        case .running:
            // Le compteur de tentatives n'est **pas** remis à zéro ici : un
            // process qui démarre puis meurt aussitôt le remettrait à zéro à
            // chaque essai, et la boucle serait éternelle. C'est `failOrRetry`
            // qui le remet à zéro, une fois la connexion prouvée durable.
            connectedAt = Date()
            connection = degradation.isDegraded
                ? .degraded(reason: degradation.bannerTitle)
                : .connected

        case .exited(let code):
            lastExitCode = code
            guard !isClosing else { return }
            if isSuspended {
                // Mort pendant la veille : on s'en occupe au réveil, pas ici.
                connection = .reconnecting(attempt: 0)
                return
            }
            if reconnectAttempt > 0 {
                // On était en train de retenter : ce départ est un échec.
                failOrRetry()
            } else {
                connection = .idle
                connectedAt = nil
            }
        }
    }

    // MARK: - Entrées / sorties

    func send(_ data: ArraySlice<UInt8>) {
        pty.send(Data(data))
    }

    /// Écrit une commande dans le terminal **sans l'exécuter** : le curseur
    /// reste en fin de ligne, l'utilisateur appuie lui-même sur Entrée (§6).
    func type(_ text: String) {
        pty.send(Data(text.utf8))
    }

    /// Écrit **et** exécute. C'est ce que le §11 demande pour la configuration
    /// de clé : `ssh-copy-id` doit réclamer son mot de passe dans un vrai TTY,
    /// sous les yeux de l'utilisateur.
    func run(_ command: String) {
        type(command + "\n")
    }

    func resize(rows: Int, cols: Int) {
        size = (rows, cols)
        lastGeometry = (UInt16(max(1, rows)), UInt16(max(1, cols)))
        pty.resize(rows: lastGeometry.rows, cols: lastGeometry.cols)
    }

    func updateTitle(_ new: String) {
        title = new.isEmpty ? name : new
    }

    // MARK: - Veille et réveil (§8)

    /// Le Mac s'endort. On marque, on ne tue rien : avec mosh, la session
    /// survit sans qu'on ait à toucher à quoi que ce soit.
    func systemWillSleep() {
        isSuspended = true
        guard connection.isLive else { return }
        connection = .reconnecting(attempt: 0)
    }

    /// Le Mac se réveille. Si le process est vivant — le cas normal avec mosh —
    /// il n'y a rien à faire. S'il est mort, on relance exactement la même
    /// commande : `tmux new -A` retrouve la session telle qu'elle était.
    func systemDidWake() {
        isSuspended = false
        guard !isClosing else { return }

        if pty.currentState == .running {
            connection = degradation.isDegraded
                ? .degraded(reason: degradation.bannerTitle)
                : .connected
            return
        }

        // Un échec définitif reste définitif : on n'annule pas la décision de
        // l'utilisateur en rouvrant le capot.
        if case .failed = connection { return }

        reconnectAttempt = 0
        scheduleReconnect(immediately: true)
    }

    /// Relance à la demande, après un échec — c'est l'action que le §8 attend
    /// de l'utilisateur plutôt qu'une boucle silencieuse.
    func reconnectNow() {
        guard !isClosing else { return }
        reconnectAttempt = 0
        lastExitCode = nil
        scheduleReconnect(immediately: true)
    }

    private func scheduleReconnect(immediately: Bool) {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = immediately ? 0 : policy.delay(forAttempt: attempt)
        connection = .reconnecting(attempt: attempt)

        reconnectTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self, !self.isClosing else { return }
            self.relaunch()
        }
    }

    /// Remplace le PTY : l'ancien est mort, et un `PTYProcess` ne se rejoue pas.
    private func relaunch() {
        pty.terminate()
        pty = PTYProcess()
        bind(pty)
        connectedAt = nil
        launchedAt = Date()
        promptDetector.reset()

        do {
            try pty.start(
                command: command,
                rows: lastGeometry.rows,
                cols: lastGeometry.cols,
                environment: mergedEnvironment
            )
        } catch {
            failOrRetry(reason: error.localizedDescription)
        }
    }

    /// Une tentative vient d'échouer. On retente, ou on s'arrête et on attend.
    private func failOrRetry(reason: String? = nil) {
        let lifetime = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        let reallyFailed = connectedAt == nil || policy.countsAsFailure(lifetime: lifetime)

        // Une connexion qui a vraiment vécu puis s'est terminée n'est pas un
        // échec d'authentification : c'est une session qu'on a quittée.
        guard reallyFailed else {
            connection = .idle
            reconnectAttempt = 0
            return
        }

        guard policy.shouldRetry(afterAttempt: reconnectAttempt) else {
            connection = .failed(reason: reason ?? policy.giveUpReason(lastExitCode: lastExitCode))
            reconnectTask?.cancel()
            reconnectTask = nil
            return
        }
        scheduleReconnect(immediately: false)
    }

    // MARK: - Fermeture

    /// L'utilisateur ferme l'onglet : on annule la reconnexion en cours, comme
    /// le demande le §8, et on coupe le process.
    func terminate() {
        isClosing = true
        reconnectTask?.cancel()
        reconnectTask = nil
        pty.terminate()
    }
}
