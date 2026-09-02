//
//  TmuxInspector.swift
//  Latch
//
//  SPEC §12, v0.4 : peupler la barre latérale avec les **vraies** fenêtres tmux.
//
//  Le mode contrôle (`tmux -CC`) est une autre façon d'y arriver : il faudrait
//  alors implémenter le protocole, démultiplexer `%output` vers plusieurs vues
//  et refaire toute la couche de rendu. Interroger tmux donne la même barre
//  latérale sans toucher au terminal, qui lui fonctionne.
//

import Combine
import Foundation

// MARK: - Modèle

/// Une fenêtre telle que tmux la voit, à l'instant où on l'a demandée.
struct LiveWindow: Identifiable, Equatable {
    var session: String
    var index: Int
    var name: String
    var isActive: Bool
    /// Ce qui tourne dans le panneau actif : `claude`, `vim`, `bash`…
    var currentCommand: String?

    var id: String { "\(session):\(index)" }

    /// La cible que comprend `tmux select-window -t`.
    var target: String { "\(session):\(index)" }
}

/// Ce que la barre latérale peut décider elle-même, sans attendre le serveur.
///
/// La boucle d'inspection ne repasse que toutes les trois secondes : cliquer
/// une fenêtre et voir la sélection bouger trois secondes plus tard donne une
/// app en carton, alors que l'action, elle, est partie tout de suite. On
/// applique donc le résultat attendu sur-le-champ, et le tour suivant confirme
/// — ou corrige, si tmux n'était pas d'accord.
enum TmuxOptimism {

    /// Une seule fenêtre est active à la fois, dans une session donnée.
    static func selecting(index: Int, in windows: [LiveWindow]) -> [LiveWindow] {
        guard windows.contains(where: { $0.index == index }) else { return windows }
        return windows.map { window in
            var copy = window
            copy.isActive = window.index == index
            return copy
        }
    }

    static func renaming(id: String, to name: String, in windows: [LiveWindow]) -> [LiveWindow] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return windows }
        return windows.map { window in
            guard window.id == id else { return window }
            var copy = window
            copy.name = trimmed
            return copy
        }
    }

    static func removing(id: String, from windows: [LiveWindow]) -> [LiveWindow] {
        windows.filter { $0.id != id }
    }
}

/// Une session telle que tmux la connaît, avec de quoi juger si on l'a oubliée.
struct LiveSession: Identifiable, Equatable {
    var name: String
    var created: Date
    var isAttached: Bool
    var windowCount: Int

    var id: String { name }

    /// « il y a 3 j », « il y a 2 h ». Assez pour décider quoi en faire.
    var age: String {
        let seconds = Date().timeIntervalSince(created)
        switch seconds {
        case ..<90: return localized("à l'instant")
        case ..<3600: return String(format: localized("il y a %d min"), Int(seconds / 60))
        case ..<86400: return String(format: localized("il y a %d h"), Int(seconds / 3600))
        default: return String(format: localized("il y a %d j"), Int(seconds / 86400))
        }
    }

    /// La même chose en deux caractères : la barre latérale fait 180 px, et le
    /// nom de la session compte plus que son âge.
    var shortAge: String {
        let seconds = Date().timeIntervalSince(created)
        switch seconds {
        case ..<90: return localized("maintenant")
        case ..<3600: return String(format: localized("%d min"), Int(seconds / 60))
        case ..<86400: return String(format: localized("%d h"), Int(seconds / 3600))
        default: return String(format: localized("%d j"), Int(seconds / 86400))
        }
    }

    var summary: String {
        let windows = windowCount == 1
            ? localized("1 fenêtre")
            : String(format: localized("%d fenêtres"), windowCount)
        return "\(windows), \(age)"
    }

    static func parse(fields: [String]) -> LiveSession? {
        guard fields.count >= 4,
              let created = TimeInterval(fields[1]),
              let windows = Int(fields[3])
        else { return nil }
        return LiveSession(
            name: fields[0],
            created: Date(timeIntervalSince1970: created),
            isAttached: fields[2] == "1",
            windowCount: windows
        )
    }
}

// MARK: - Interrogation

@MainActor
final class TmuxInspector: ObservableObject {

    /// L'hôte à interroger, ou `nil` pour le Mac : une session locale a des
    /// fenêtres et un dépôt comme n'importe quelle autre.
    let alias: String?

    /// Les fenêtres par session tmux.
    @Published private(set) var windows: [String: [LiveWindow]] = [:]
    /// L'état git du panneau actif, par session (§9.1).
    @Published private(set) var repositories: [String: LiveRepository] = [:]
    /// Toutes les sessions de l'hôte, y compris celles qu'aucun raccourci ne
    /// désigne : sans ça, elles s'accumulent sans que personne les voie.
    @Published private(set) var sessions: [LiveSession] = []

    /// Le répertoire du panneau actif de chaque session.
    @Published private(set) var directories: [String: String] = [:]

    /// Les sélections décidées ici et pas encore confirmées par le serveur,
    /// avec l'instant du clic. Une réponse déjà en vol quand on a cliqué
    /// porte l'ancienne fenêtre active : sans ça, la sélection reviendrait en
    /// arrière une fraction de seconde avant de repartir.
    private var optimisticSelections: [String: (index: Int, since: Date)] = [:]

    /// Au-delà, on considère que le clic s'est perdu et on refait confiance au
    /// serveur : un tour de boucle, plus un aller-retour ssh.
    private static let optimismGrace: TimeInterval = 5

    /// Le séparateur doit être improbable dans un nom de fenêtre — une
    /// tabulation l'est, un espace ne l'est pas.
    nonisolated static let separator = "\u{1F}"
    nonisolated private static let recordEnd = "LATCH_END"
    nonisolated static let gitPrefix = "LATCH_GIT"
    nonisolated static let pathPrefix = "LATCH_CWD"
    nonisolated static let sessionPrefix = "LATCH_SES"

    /// Une boucle côté serveur plutôt qu'un ssh par sondage : une connexion,
    /// tenue ouverte, qui réémet tout régulièrement.
    ///
    /// Le même passage relève les fenêtres et l'état git du panneau actif (§9.1) :
    /// deux questions posées au même endroit au même moment, autant ne pas
    /// ouvrir deux connexions pour ça.
    nonisolated static func watchCommand(every seconds: Int = 3, tmux: String = "tmux") -> String {
        let format = [
            "#{session_name}", "#{window_index}", "#{window_name}",
            "#{window_active}", "#{pane_current_command}",
        ].joined(separator: separator)

        let sessionFormat = [
            "\(sessionPrefix)#{session_name}", "#{session_created}",
            "#{session_attached}", "#{session_windows}",
        ].joined(separator: separator)

        return "while :; do \(tmux) list-windows -a -F '\(format)' 2>/dev/null; "
            + "\(tmux) list-sessions -F '\(sessionFormat)' 2>/dev/null; "
            + gitLoop(tmux: tmux) + "; echo '\(recordEnd)'; sleep \(seconds); done"
    }

    /// Le dépôt du panneau actif de la fenêtre active : c'est là que le travail
    /// se fait, et donc celui qui intéresse la barre d'état.
    ///
    /// `IFS` prend le séparateur pour que les chemins à espaces survivent au
    /// `read`, et un répertoire hors dépôt est simplement sauté.
    nonisolated private static func gitLoop(tmux: String) -> String {
        let paneFormat = ["#{session_name}", "#{pane_current_path}"].joined(separator: separator)
        return [
            "\(tmux) list-panes -a -f '#{&&:#{window_active},#{pane_active}}'",
            "-F '\(paneFormat)' 2>/dev/null |",
            "while IFS='\(separator)' read -r s p; do",
            // Émis pour tout panneau, dépôt ou non : c'est ce qui relie une
            // session Claude — qui ne connaît qu'un `cwd` — à une session tmux.
            "printf '\(pathPrefix)%s\(separator)%s\\n' \"$s\" \"$p\";",
            "b=$(git -C \"$p\" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue;",
            "d=$(git -C \"$p\" diff --shortstat 2>/dev/null);",
            "printf '\(gitPrefix)%s\(separator)%s\(separator)%s\\n' \"$s\" \"$b\" \"$d\";",
            "done",
        ].joined(separator: " ")
    }

    private var process: Process?
    private var buffer = Data()
    private var pending: [LiveWindow] = []
    private var pendingRepositories: [String: LiveRepository] = [:]
    private var pendingSessions: [LiveSession] = []
    private var pendingDirectories: [String: String] = [:]
    private var retryTask: Task<Void, Never>?
    private var attempt = 0
    private var isStopped = false
    private let policy = ReconnectionPolicy(base: 2, cap: 30, maxAttempts: .max)

    init(alias: String?) {
        self.alias = alias
    }

    /// Le chemin absolu de tmux sur le Mac : le `PATH` d'une app lancée depuis
    /// le Finder ne mène nulle part (§6, appliqué localement).
    private var localTmux: String? { LocalTools.path(of: "tmux") }

    /// Le canal partagé avec la connexion d'inspection.
    ///
    /// Chaque commande tmux — sélectionner, renommer, fermer — ouvrait sa
    /// propre connexion ssh : poignée de main, authentification, shell, pour
    /// une ligne. `ControlMaster` la fait passer par la connexion déjà tenue
    /// ouverte par la boucle, ce qui la ramène à un aller-retour réseau.
    ///
    /// La socket vit dans le dossier temporaire, nommée d'après l'alias. Si
    /// elle manque — la boucle n'a pas encore démarré, ou elle est tombée —
    /// `ControlMaster=no` côté client fait simplement une connexion normale.
    private var controlPath: String? {
        guard let alias else { return nil }
        let digest = alias.unicodeScalars.reduce(into: UInt64(5381)) { hash, scalar in
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        return NSTemporaryDirectory() + "latch-\(String(digest, radix: 36)).sock"
    }

    /// Les options ssh d'une commande ponctuelle : elle emprunte le canal, sans
    /// jamais chercher à l'établir elle-même.
    private var sharedChannelOptions: [String] {
        guard let controlPath else { return [] }
        return ["-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)"]
    }

    deinit {
        process?.terminate()
    }

    // MARK: Cycle de vie

    func start() {
        guard process == nil, !isStopped else { return }
        launch()
    }

    func stop() {
        isStopped = true
        retryTask?.cancel()
        process?.terminate()
        process = nil
        windows = [:]
        repositories = [:]
        sessions = []
        directories = [:]
    }

    private func launch() {
        let task = Process()
        if let alias {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ConnectTimeout=10",
            ]
            // La boucle tient le canal ouvert pour les commandes ponctuelles.
            if let controlPath {
                // Une socket laissée par une boucle tuée empêcherait d'ouvrir
                // le canal, et les commandes repartiraient chacune de zéro
                // sans que rien ne le dise. La boucle en est propriétaire.
                try? FileManager.default.removeItem(atPath: controlPath)
                task.arguments? += [
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(controlPath)",
                    "-o", "ControlPersist=no",
                ]
            }
            task.arguments? += [alias, Self.watchCommand()]
        } else {
            // Sans tmux local, il n'y a rien à observer : on n'ouvre pas un
            // shell pour qu'il échoue en boucle.
            guard let tmux = localTmux else { return }
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", Self.watchCommand(tmux: ShellQuoting.quoted(tmux))]
        }

        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(chunk) }
        }
        task.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.handleTermination() }
        }

        do {
            try task.run()
            process = task
            attempt = 0
        } catch {
            process = nil
            scheduleRetry()
        }
    }

    private func handleTermination() {
        process = nil
        buffer.removeAll()
        pending.removeAll()
        pendingRepositories.removeAll()
        pendingSessions.removeAll()
        guard !isStopped else { return }
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        attempt += 1
        let delay = policy.delay(forAttempt: attempt)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.launch()
        }
    }

    // MARK: Lecture

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fin de lot : on publie d'un coup, pour que la barre latérale ne
        // clignote pas pendant qu'un lot arrive morceau par morceau.
        if trimmed == Self.recordEnd {
            windows = honouringPendingSelections(Dictionary(grouping: pending, by: \.session))
            repositories = pendingRepositories
            sessions = pendingSessions.sorted { $0.name < $1.name }
            directories = pendingDirectories
            pending.removeAll()
            pendingRepositories.removeAll()
            pendingSessions.removeAll()
            pendingDirectories.removeAll()
            return
        }

        if trimmed.hasPrefix(Self.sessionPrefix) {
            let fields = String(trimmed.dropFirst(Self.sessionPrefix.count))
                .components(separatedBy: Self.separator)
            if let session = LiveSession.parse(fields: fields) { pendingSessions.append(session) }
            return
        }

        if trimmed.hasPrefix(Self.pathPrefix) {
            let fields = String(trimmed.dropFirst(Self.pathPrefix.count))
                .components(separatedBy: Self.separator)
            if fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty {
                pendingDirectories[fields[0]] = fields[1]
            }
            return
        }

        if trimmed.hasPrefix(Self.gitPrefix) {
            let fields = String(trimmed.dropFirst(Self.gitPrefix.count))
                .components(separatedBy: Self.separator)
            if let repository = LiveRepository.parse(fields: fields) {
                pendingRepositories[repository.session] = repository
            }
            return
        }

        if let window = Self.parse(line: trimmed) { pending.append(window) }
    }

    /// Garde la fenêtre choisie au clic tant que le serveur n'a pas répondu à
    /// son sujet, et lâche prise dès qu'il confirme — ou que l'attente a trop
    /// duré pour être encore crédible.
    private func honouringPendingSelections(
        _ fresh: [String: [LiveWindow]]
    ) -> [String: [LiveWindow]] {
        guard !optimisticSelections.isEmpty else { return fresh }
        var result = fresh
        let now = Date()

        for (session, pending) in optimisticSelections {
            guard let windows = result[session] else {
                optimisticSelections[session] = nil
                continue
            }
            let confirmed = windows.contains { $0.index == pending.index && $0.isActive }
            if confirmed || now.timeIntervalSince(pending.since) > Self.optimismGrace {
                optimisticSelections[session] = nil
                continue
            }
            result[session] = TmuxOptimism.selecting(index: pending.index, in: windows)
        }
        return result
    }

    nonisolated static func parse(line: String) -> LiveWindow? {
        let fields = line.components(separatedBy: separator)
        guard fields.count >= 5, let index = Int(fields[1]) else { return nil }

        let command = fields[4].trimmingCharacters(in: .whitespaces)
        return LiveWindow(
            session: fields[0],
            index: index,
            name: fields[2],
            isActive: fields[3] == "1",
            currentCommand: command.isEmpty ? nil : command
        )
    }

    // MARK: Action

    /// Crée les fenêtres déclarées qui manquent, et **seulement** celles-là.
    ///
    /// Les créer depuis la commande de session ne les faisait naître qu'à la
    /// première connexion : ajouter une fenêtre à un raccourci déjà utilisé ne
    /// produisait rien, ce qui rendait la section incompréhensible. On
    /// rapproche donc le déclaré du réel à chaque connexion — par nom, ce qui
    /// est idempotent et ne duplique jamais.
    func reconcile(_ declared: [TmuxWindow], inSession session: String) {
        guard !declared.isEmpty, windows[session] != nil else { return }
        let existing = Set((windows[session] ?? []).map(\.name))

        for window in declared where !existing.contains(window.name) {
            let name = window.name.trimmingCharacters(in: .whitespaces)
            let command = window.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else { continue }
            run(["new-window", "-d", "-t", session + ":", "-n", name, command])
        }
    }

    /// Renomme une fenêtre. tmux ne la renomme pas tout seul quand un raccourci
    /// change : c'est une action de l'utilisateur.
    func renameWindow(_ window: LiveWindow, to name: String) {
        if let windows = windows[window.session] {
            self.windows[window.session] =
                TmuxOptimism.renaming(id: window.id, to: name, in: windows)
        }
        run(["rename-window", "-t", window.target, name])
    }

    func newWindow(inSession session: String) {
        run(["new-window", "-t", session + ":"])
    }

    func killWindow(_ window: LiveWindow) {
        if let windows = windows[window.session] {
            self.windows[window.session] = TmuxOptimism.removing(id: window.id, from: windows)
        }
        run(["kill-window", "-t", window.target])
    }

    /// Renomme une session sur l'hôte. C'est ce qui évite de fabriquer une
    /// orpheline quand un raccourci change de nom : le travail suit.
    func rename(from old: String, to new: String) {
        run(["rename-session", "-t", old, new])
    }

    /// Ferme une session. Jamais automatique, jamais sans confirmation :
    /// derrière un nom oublié peut tourner quelque chose qui compte.
    func kill(_ name: String) {
        run(["kill-session", "-t", name])
    }

    private func run(_ arguments: [String]) {
        let task = Process()
        if let alias {
            let remote = (["tmux"] + arguments).map(ShellQuoting.quoted).joined(separator: " ")
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments =
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + sharedChannelOptions + [alias, remote]
        } else {
            guard let tmux = localTmux else { return }
            task.executableURL = URL(fileURLWithPath: tmux)
            task.arguments = arguments
        }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    /// Bascule la session distante sur cette fenêtre. Le terminal attaché suit
    /// tout seul : c'est tmux qui décide de ce qu'il affiche.
    func select(_ window: LiveWindow) {
        // La sélection se voit avant de partir : l'aller-retour ssh et le tour
        // de boucle qui la confirmera prennent, ensemble, plusieurs secondes.
        if let windows = windows[window.session] {
            self.windows[window.session] =
                TmuxOptimism.selecting(index: window.index, in: windows)
            optimisticSelections[window.session] = (window.index, Date())
        }

        let task = Process()
        if let alias {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments =
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + sharedChannelOptions
                + [alias, "tmux select-window -t \(ShellQuoting.quoted(window.target))"]
        } else {
            guard let tmux = localTmux else { return }
            task.executableURL = URL(fileURLWithPath: tmux)
            task.arguments = ["select-window", "-t", window.target]
        }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}
