//
//  PTYProcess.swift
//  Latch
//
//  Couche la plus basse (SPEC §3.1). Elle ouvre un pseudo-terminal, y lance un
//  process et expose des octets. Elle ne sait pas ce qu'est ssh, mosh ou tmux :
//  toute logique métier appartient aux couches au-dessus.
//

import Combine
import Darwin
import Foundation

// MARK: - État

/// État du process attaché au PTY.
enum PTYState: Equatable {
    case idle
    case running

    /// Code de sortie. Un process tué par un signal `N` est rapporté comme
    /// `128 + N`, la convention des shells POSIX, pour garder un seul cas.
    case exited(code: Int32)
}

enum PTYError: LocalizedError {
    case alreadyRunning
    case forkFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Ce PTY a déjà un process attaché."
        case .forkFailed(let code):
            return "forkpty a échoué : \(String(cString: strerror(code))) (errno \(code))."
        }
    }
}

// MARK: - PTYProcess

/// Encapsule `forkpty(3)` : un process fils sous pseudo-terminal, son flux de
/// sortie, son redimensionnement et sa fin de vie.
///
/// Les publications (`state`, `output`) arrivent sur la file principale, prêtes
/// à alimenter l'interface.
final class PTYProcess {

    // MARK: Publications

    private let stateSubject = CurrentValueSubject<PTYState, Never>(.idle)
    private let outputSubject = PassthroughSubject<Data, Never>()

    /// État courant du process, rejoué à l'abonnement.
    var state: AnyPublisher<PTYState, Never> {
        stateSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Octets bruts émis par le process. Aucun décodage : c'est le terminal qui
    /// sait ce qu'ils veulent dire.
    var output: AnyPublisher<Data, Never> {
        outputSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Lecture synchrone de l'état, pour les décisions qui ne peuvent pas
    /// attendre un tour de boucle (la reconnexion au réveil, SPEC §8).
    var currentState: PTYState { stateSubject.value }

    // MARK: Identité du process

    private(set) var pid: pid_t = -1
    private(set) var masterFD: Int32 = -1

    // MARK: Files

    /// Lecture du descripteur maître et sérialisation de l'état interne.
    private let ioQueue = DispatchQueue(label: "app.latch.pty.io")
    /// File dédiée au `waitpid`, pour ne jamais bloquer la lecture.
    private let waitQueue = DispatchQueue(label: "app.latch.pty.wait")

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var killWorkItem: DispatchWorkItem?

    /// Code de sortie connu mais pas encore publié : on attend d'avoir vidé le
    /// PTY, sinon les derniers octets du process sont perdus.
    private var pendingExitCode: Int32?
    private var readingFinished = false
    private var didPublishExit = false

    private static let readBufferSize = 64 * 1024

    /// Ce que SwiftTerm émule, et donc la seule valeur honnête pour `TERM`.
    static let defaultTermName = "xterm-256color"

    /// Variables qui décrivent le terminal *hôte* : les transmettre au serveur
    /// distant ne peut que l'induire en erreur.
    private static let hostTerminalVariables = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "TERMINFO", "TERMINFO_DIRS", "COLUMNS", "LINES",
    ]

    deinit {
        // Pas de `terminate()` ici : un deinit ne doit pas prendre 2 s.
        if pid > 0 { killpg(pid, SIGHUP) }
        if masterFD >= 0 { close(masterFD) }
    }

    // MARK: - Démarrage

    /// Lance `command` via `/bin/sh -c` dans un pseudo-terminal neuf.
    ///
    /// - Parameters:
    ///   - command: la ligne de commande complète, telle que produite par la
    ///     couche du dessus. Elle n'est pas réinterprétée ici.
    ///   - rows: hauteur initiale de la fenêtre du terminal.
    ///   - cols: largeur initiale.
    ///   - termName: valeur de `TERM` imposée au fils. Elle doit décrire le
    ///     terminal réellement émulé, pas celui d'où Latch a été lancé.
    ///   - environment: environnement du fils. Par défaut celui du process
    ///     courant, expurgé de l'identité du terminal hôte.
    func start(
        command: String,
        rows: UInt16 = 24,
        cols: UInt16 = 80,
        termName: String = PTYProcess.defaultTermName,
        environment: [String: String]? = nil
    ) throws {
        guard pid < 0 else { throw PTYError.alreadyRunning }

        var env = environment ?? ProcessInfo.processInfo.environment

        // `TERM` est imposé, jamais hérité. Lancée depuis Ghostty, Latch
        // hériterait de `xterm-ghostty` et le tmux distant refuserait de
        // démarrer sur « missing or unsuitable terminal » : le terminfo du
        // terminal hôte n'existe pas sur le serveur, et de toute façon ce
        // n'est pas lui qu'on émule.
        env["TERM"] = termName
        for stale in Self.hostTerminalVariables { env.removeValue(forKey: stale) }
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        // Tout ce qui alloue doit l'être AVANT le fork : entre `forkpty` et
        // `execve`, seuls les appels async-signal-safe sont légaux, et `strdup`
        // dans le fils peut se bloquer sur un verrou de malloc hérité.
        let cArgv = Self.makeCStringArray(["/bin/sh", "-c", command])
        let cEnv = Self.makeCStringArray(env.map { "\($0.key)=\($0.value)" })
        let cPath = strdup("/bin/sh")

        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1

        let child = forkpty(&master, nil, nil, &size)

        if child == 0 {
            // Fils. `forkpty` a déjà appelé `login_tty` : nouvelle session,
            // terminal de contrôle en place. Il ne reste qu'à se remplacer.
            execve(cPath, cArgv, cEnv)
            _exit(127)  // execve n'a pas rendu la main : /bin/sh introuvable.
        }

        Self.freeCStringArray(cArgv)
        Self.freeCStringArray(cEnv)
        free(cPath)

        guard child > 0 else {
            throw PTYError.forkFailed(code: errno)
        }

        pid = child
        masterFD = master
        pendingExitCode = nil
        readingFinished = false
        didPublishExit = false

        // Lecture non bloquante : le DispatchSource nous réveille quand il y a
        // quelque chose, on ne veut jamais rester coincé dans `read`.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        stateSubject.send(.running)
        startReading(fd: master)
        startWatchingExit(pid: child)
    }

    // MARK: - Entrées / sorties

    /// Écrit des octets vers le process (les frappes clavier de l'utilisateur).
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(self.masterFD, base + offset, raw.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written == -1 && (errno == EINTR || errno == EAGAIN) { continue }
                    return  // Le descripteur est mort : la fin de vie est gérée ailleurs.
                }
            }
        }
    }

    /// Propage la taille de la fenêtre au process (`TIOCSWINSZ`), qui la reçoit
    /// sous forme de `SIGWINCH`.
    @discardableResult
    func resize(rows: UInt16, cols: UInt16) -> Bool {
        guard masterFD >= 0, rows > 0, cols > 0 else { return false }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        return ioctl(masterFD, TIOCSWINSZ, &size) == 0
    }

    // MARK: - Fin de vie

    /// `SIGHUP` au groupe de process, puis `SIGKILL` s'il est encore là au bout
    /// de 2 s. On vise le groupe et non le seul fils : `/bin/sh -c ssh …` laisse
    /// des descendants qu'un signal au seul shell n'atteindrait pas.
    func terminate() {
        guard pid > 0 else { return }
        let target = pid

        if killpg(target, SIGHUP) == -1 { kill(target, SIGHUP) }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pid == target else { return }
            if killpg(target, SIGKILL) == -1 { kill(target, SIGKILL) }
        }
        killWorkItem?.cancel()
        killWorkItem = item
        waitQueue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    // MARK: - Interne

    private func startReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.readBufferSize)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let count = read(fd, buffer, Self.readBufferSize)
                if count > 0 {
                    self.outputSubject.send(Data(bytes: buffer, count: count))
                    if count < Self.readBufferSize { return }
                    continue  // Le tampon était plein : il reste peut-être à lire.
                }
                if count == -1 && errno == EINTR { continue }
                if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                // 0 octet, ou EIO : sur macOS, le côté esclave vient de fermer.
                self.finishReading()
                return
            }
        }

        source.setCancelHandler { [weak self] in
            buffer.deallocate()
            close(fd)
            self?.masterFD = -1
        }

        readSource = source
        source.resume()
    }

    private func startWatchingExit(pid child: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: child, eventMask: .exit, queue: waitQueue
        )
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            let reaped = waitpid(child, &status, 0)
            let code = reaped == child ? Self.exitCode(from: status) : -1
            self?.ioQueue.async {
                guard let self else { return }
                self.pendingExitCode = code
                self.publishExitIfReady()
            }
            source.cancel()
        }
        exitSource = source
        source.resume()
    }

    /// Appelé sur `ioQueue` quand le PTY n'a plus rien à donner.
    private func finishReading() {
        readingFinished = true
        readSource?.cancel()
        readSource = nil
        publishExitIfReady()
    }

    /// Appelé sur `ioQueue`. On ne publie `.exited` qu'une fois les deux
    /// conditions réunies : process récolté ET flux vidé.
    private func publishExitIfReady() {
        guard !didPublishExit, readingFinished, let code = pendingExitCode else { return }
        didPublishExit = true
        killWorkItem?.cancel()
        killWorkItem = nil
        pid = -1
        stateSubject.send(.exited(code: code))
    }

    /// Décode le statut de `waitpid`. Les macros `WIFEXITED` et compagnie ne
    /// sont pas importées en Swift, il faut les refaire à la main.
    private static func exitCode(from status: Int32) -> Int32 {
        let lowSeven = status & 0x7F
        if lowSeven == 0 {
            return (status >> 8) & 0xFF  // WIFEXITED / WEXITSTATUS
        }
        if lowSeven != 0x7F {
            return 128 + lowSeven  // WIFSIGNALED / WTERMSIG
        }
        return -1  // Arrêté, pas terminé : ne devrait pas arriver ici.
    }

    // MARK: Tableaux C

    private static func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        array.forEach { free($0) }
    }
}
