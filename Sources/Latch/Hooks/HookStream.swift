//
//  HookStream.swift
//  Latch
//
//  La connexion ssh secondaire du §10 : elle ne sert qu'à suivre le journal
//  d'événements, sans TTY et sans rien envoyer. Si elle tombe, la session de
//  travail n'en sait rien — c'est tout l'intérêt de la garder séparée.
//

import Combine
import Foundation

@MainActor
final class HookStream: ObservableObject {

    let alias: String
    /// `-R port:127.0.0.1:port` : c'est par ce tunnel que Claude Code, sur le
    /// serveur, atteint le serveur MCP de Latch (§10). La connexion des hooks
    /// le porte parce qu'elle existe déjà, et pour tous les transports —
    /// y compris mosh, qui n'est pas du ssh.
    var remoteForward: String?

    @Published private(set) var activity = ClaudeActivity()
    /// Vrai quand la connexion secondaire tient. Faux ne veut pas dire que la
    /// session principale est tombée.
    @Published private(set) var isFollowing = false

    /// Appelé pour chaque événement, après mise à jour de `activity`.
    var onEvent: ((HookEvent) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var retryTask: Task<Void, Never>?
    private var attempt = 0
    private var isStopped = false

    private let policy = ReconnectionPolicy(base: 2, cap: 30, maxAttempts: .max)

    init(alias: String, remoteForward: String? = nil) {
        self.alias = alias
        self.remoteForward = remoteForward
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Cycle de vie

    func start() {
        guard process == nil, !isStopped else { return }
        launch()
    }

    func stop() {
        isStopped = true
        retryTask?.cancel()
        retryTask = nil
        process?.terminate()
        process = nil
        isFollowing = false
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            // Pas de TTY, pas d'agent, pas d'interaction : cette connexion doit
            // vivre en arrière-plan sans jamais réclamer quoi que ce soit.
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=no",
        ]
        if let remoteForward { arguments += ["-R", remoteForward] }
        arguments += [alias, HookInstaller.followCommand]
        task.arguments = arguments

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
            isFollowing = true
            attempt = 0
        } catch {
            process = nil
            isFollowing = false
            scheduleRetry()
        }
    }

    private func handleTermination() {
        process?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process = nil
        isFollowing = false
        buffer.removeAll()
        guard !isStopped else { return }
        scheduleRetry()
    }

    /// Le flux de hooks se rattrape indéfiniment, contrairement à une session :
    /// il n'y a rien à perdre à réessayer, et un serveur qui revient doit
    /// retrouver son indicateur sans intervention.
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

    // MARK: - Lecture

    private func consume(_ chunk: Data) {
        buffer.append(chunk)

        // Une ligne peut arriver en deux morceaux : on ne traite que ce qui est
        // complet, et on garde le reste pour la prochaine fois.
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)

            guard let event = HookEvent.parse(line: String(decoding: line, as: UTF8.self)) else {
                continue
            }
            activity.apply(event)
            onEvent?(event)
        }

        // Une ligne démesurée est une ligne corrompue : on ne garde pas un
        // tampon qui grossit sans fin.
        if buffer.count > 1 << 20 { buffer.removeAll() }
    }
}
