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

// MARK: - Interrogation

@MainActor
final class TmuxInspector: ObservableObject {

    let alias: String

    /// Les fenêtres par session tmux.
    @Published private(set) var windows: [String: [LiveWindow]] = [:]

    /// Le séparateur doit être improbable dans un nom de fenêtre — une
    /// tabulation l'est, un espace ne l'est pas.
    nonisolated private static let separator = "\u{1F}"
    nonisolated private static let recordEnd = "LATCH_END"

    /// Une boucle côté serveur plutôt qu'un ssh par sondage : une connexion,
    /// tenue ouverte, qui réémet la liste régulièrement.
    nonisolated static func watchCommand(every seconds: Int = 3) -> String {
        let format = [
            "#{session_name}", "#{window_index}", "#{window_name}",
            "#{window_active}", "#{pane_current_command}",
        ].joined(separator: separator)

        return "while :; do tmux list-windows -a -F '\(format)' 2>/dev/null; "
            + "echo '\(recordEnd)'; sleep \(seconds); done"
    }

    private var process: Process?
    private var buffer = Data()
    private var pending: [LiveWindow] = []
    private var retryTask: Task<Void, Never>?
    private var attempt = 0
    private var isStopped = false
    private let policy = ReconnectionPolicy(base: 2, cap: 30, maxAttempts: .max)

    init(alias: String) {
        self.alias = alias
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
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10",
            alias,
            Self.watchCommand(),
        ]

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
            pending.removeAll()
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

    /// Bascule la session distante sur cette fenêtre. Le terminal attaché suit
    /// tout seul : c'est tmux qui décide de ce qu'il affiche.
    func select(_ window: LiveWindow) {
        let command = "tmux select-window -t \(ShellQuoting.quoted(window.target))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias, command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}
