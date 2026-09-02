//
//  TerminalSession.swift
//  Latch
//
//  Le pont entre un `PTYProcess` et l'interface. En v0.1 la commande est codée
//  en dur (SPEC §12) ; en v0.2 elle viendra du `CommandBuilder`.
//

import Combine
import Foundation

@MainActor
final class TerminalSession: ObservableObject {

    /// Titre annoncé par le terminal distant (séquence OSC 0/2).
    @Published private(set) var title: String
    @Published private(set) var state: PTYState = .idle
    /// Dernière taille annoncée par la vue, utile à la barre d'état.
    @Published private(set) var size: (rows: Int, cols: Int) = (0, 0)

    /// Le nom affiché dans la barre latérale et l'onglet.
    let name: String
    /// La commande exécutée localement via `/bin/sh -c`.
    let command: String

    private let pty = PTYProcess()
    private var cancellables = Set<AnyCancellable>()

    /// Octets reçus du process, à pousser dans le terminal.
    var output: AnyPublisher<Data, Never> { pty.output }

    init(name: String, command: String) {
        self.name = name
        self.command = command
        self.title = name

        pty.state
            .sink { [weak self] in self?.state = $0 }
            .store(in: &cancellables)
    }

    /// Démarre le process. Appelé par la vue une fois qu'elle connaît sa taille,
    /// pour que le premier `winsize` soit déjà le bon.
    func start(rows: UInt16, cols: UInt16) {
        guard state == .idle else { return }
        do {
            try pty.start(command: command, rows: rows, cols: cols)
        } catch {
            // Rien de plus utile à faire en v0.1 : la gestion d'erreur riche
            // arrive avec `ConnectionDriver` et ses états dégradés (SPEC §3.2).
            NSLog("Latch: échec du lancement de « \(command) » — \(error.localizedDescription)")
        }
    }

    func send(_ data: ArraySlice<UInt8>) {
        pty.send(Data(data))
    }

    func resize(rows: Int, cols: Int) {
        size = (rows, cols)
        pty.resize(rows: UInt16(max(0, rows)), cols: UInt16(max(0, cols)))
    }

    func updateTitle(_ new: String) {
        title = new.isEmpty ? name : new
    }

    func terminate() {
        pty.terminate()
    }
}
