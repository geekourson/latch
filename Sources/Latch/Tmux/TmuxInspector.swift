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
        case ..<90: return "à l'instant"
        case ..<3600: return "il y a \(Int(seconds / 60)) min"
        case ..<86400: return "il y a \(Int(seconds / 3600)) h"
        default: return "il y a \(Int(seconds / 86400)) j"
        }
    }

    var summary: String {
        let windows = windowCount == 1 ? "1 fenêtre" : "\(windowCount) fenêtres"
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

    /// Le séparateur doit être improbable dans un nom de fenêtre — une
    /// tabulation l'est, un espace ne l'est pas.
    nonisolated static let separator = "\u{1F}"
    nonisolated private static let recordEnd = "LATCH_END"
    nonisolated static let gitPrefix = "LATCH_GIT"
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
    }

    private func launch() {
        let task = Process()
        if let alias {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ConnectTimeout=10",
                alias,
                Self.watchCommand(),
            ]
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
            windows = Dictionary(grouping: pending, by: \.session)
            repositories = pendingRepositories
            sessions = pendingSessions.sorted { $0.name < $1.name }
            pending.removeAll()
            pendingRepositories.removeAll()
            pendingSessions.removeAll()
            return
        }

        if trimmed.hasPrefix(Self.sessionPrefix) {
            let fields = String(trimmed.dropFirst(Self.sessionPrefix.count))
                .components(separatedBy: Self.separator)
            if let session = LiveSession.parse(fields: fields) { pendingSessions.append(session) }
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
            task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias, remote]
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
        let task = Process()
        if let alias {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments = [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias,
                "tmux select-window -t \(ShellQuoting.quoted(window.target))",
            ]
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
