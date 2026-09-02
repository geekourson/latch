//
//  TerminalSession.swift
//  Latch
//
//  Le pont entre un `PTYProcess` et l'interface : un onglet, une commande, un
//  pseudo-terminal. La commande vient du `CommandBuilder` ; cette classe ne
//  sait pas la construire et ne cherche pas à l'interpréter.
//

import Combine
import Foundation

@MainActor
final class TerminalSession: ObservableObject, Identifiable {

    nonisolated let id = UUID()

    /// Titre annoncé par le terminal distant (séquence OSC 0/2).
    @Published private(set) var title: String
    @Published private(set) var state: PTYState = .idle
    /// Dernière taille annoncée par la vue, utile à la barre d'état.
    @Published private(set) var size: (rows: Int, cols: Int) = (0, 0)

    /// Le nom affiché dans la barre latérale et l'onglet.
    let name: String
    /// La commande exécutée localement via `/bin/sh -c`.
    let command: String
    /// Le raccourci d'où vient cet onglet, s'il y en a un.
    let shortcutID: Shortcut.ID?
    /// L'alias de l'hôte, pour la pastille d'état de la barre latérale.
    let host: String
    /// Ce que la sonde a imposé de perdre en route (§6).
    let degradation: Degradation

    private let pty = PTYProcess()
    private var cancellables = Set<AnyCancellable>()

    /// Octets reçus du process, à pousser dans le terminal.
    var output: AnyPublisher<Data, Never> { pty.output }

    var isRunning: Bool { state == .running }

    init(
        name: String,
        command: String,
        shortcutID: Shortcut.ID? = nil,
        host: String = "",
        degradation: Degradation = .none
    ) {
        self.name = name
        self.command = command
        self.shortcutID = shortcutID
        self.host = host
        self.degradation = degradation
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
            NSLog("Latch: échec du lancement de « \(command) » — \(error.localizedDescription)")
        }
    }

    func send(_ data: ArraySlice<UInt8>) {
        pty.send(Data(data))
    }

    /// Écrit une commande dans le terminal **sans l'exécuter** : le curseur
    /// reste en fin de ligne, l'utilisateur appuie lui-même sur Entrée (§6).
    func type(_ text: String) {
        pty.send(Data(text.utf8))
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
