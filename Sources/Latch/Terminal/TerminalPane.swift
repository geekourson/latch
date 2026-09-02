//
//  TerminalPane.swift
//  Latch
//
//  Couche haute (SPEC §3.4) : SwiftTerm branché sur le flux d'octets d'une
//  `TerminalSession`. Aucune connaissance de ssh, mosh ou tmux ici non plus.
//

import AppKit
import Combine
import SwiftTerm
import SwiftUI

/// Marges autour du terminal (SPEC §9.1).
private let terminalPadding: CGFloat = 20
/// Interligne demandé par la SPEC §9.1. C'est un multiplicateur de la hauteur
/// de ligne de la police : 1.0 = compact, 1.8 = très aéré.
private let terminalLineSpacing: CGFloat = 1.8

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> PaddedTerminalView {
        let container = PaddedTerminalView(inset: terminalPadding)
        let terminal = container.terminalView

        terminal.font = LatchTheme.monoFont()
        terminal.lineSpacing = terminalLineSpacing
        terminal.nativeBackgroundColor = LatchTheme.background
        terminal.nativeForegroundColor = LatchTheme.text
        terminal.caretColor = LatchTheme.accent
        terminal.selectedTextBackgroundColor = LatchTheme.surfaceHigh
        terminal.installColors(LatchTheme.ansiColors)
        terminal.terminalDelegate = context.coordinator

        context.coordinator.attach(to: terminal)
        return container
    }

    func updateNSView(_ nsView: PaddedTerminalView, context: Context) {
        context.coordinator.session = session
    }

    static func dismantleNSView(_ nsView: PaddedTerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: TerminalSession
        private var cancellable: AnyCancellable?
        private weak var terminal: TerminalView?
        private var didStart = false

        init(session: TerminalSession) {
            self.session = session
        }

        /// S'abonne au flux AVANT de lancer le process : le sujet de sortie ne
        /// rejoue rien, un abonnement tardif perdrait la bannière d'accueil.
        func attach(to view: TerminalView) {
            terminal = view
            cancellable = session.output.sink { [weak view] data in
                    guard let view, !data.isEmpty else { return }
                view.feed(byteArray: ArraySlice(data))
            }
        }

        func detach() {
            cancellable?.cancel()
            cancellable = nil
            session.terminate()
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(rows: newRows, cols: newCols)
            // Le premier redimensionnement est aussi le moment où l'on connaît
            // la vraie géométrie : c'est là qu'on lance le process.
            if !didStart, newRows > 0, newCols > 0 {
                didStart = true
                session.start(rows: UInt16(newRows), cols: UInt16(newCols))
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            session.updateTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Exploité en v0.2 par la barre d'état.
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(data)
        }

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

// MARK: - Conteneur

/// Un simple porteur de marges : SwiftTerm calcule ses colonnes à partir de sa
/// propre largeur, donc le padding doit vivre dans une vue parente.
final class PaddedTerminalView: NSView {
    let terminalView: TerminalView
    private let inset: CGFloat

    init(inset: CGFloat) {
        self.inset = inset
        self.terminalView = TerminalView(frame: .zero)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = LatchTheme.background.cgColor
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) inutilisé") }

    override func layout() {
        super.layout()
        terminalView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(terminalView) ?? false
    }
}
