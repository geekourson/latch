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

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    /// Thème et typographie, recalculés par le store (SPEC §9.3).
    var style: TerminalStyle = TerminalStyle()
    /// Un onglet en arrière-plan reste en vie pour garder son flux, mais ne
    /// doit pas se redessiner : une opacité nulle n'empêche pas AppKit de
    /// repeindre la vue à chaque octet reçu, une vue masquée si.
    var isVisible = true
    /// Sa zone est la zone active : c'est lui qui reçoit le clavier.
    var isFocused = true
    /// Un clic dans le terminal rend sa zone active.
    var onActivate: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> PaddedTerminalView {
        let container = PaddedTerminalView(inset: style.padding)
        container.terminalView.terminalDelegate = context.coordinator
        container.isHidden = !isVisible
        (container.terminalView as? SelectableTerminalView)?.onActivate = onActivate
        apply(style, to: container)
        context.coordinator.appliedStyle = style
        context.coordinator.attach(to: container.terminalView)
        return container
    }

    func updateNSView(_ nsView: PaddedTerminalView, context: Context) {
        context.coordinator.session = session
        (nsView.terminalView as? SelectableTerminalView)?.onActivate = onActivate
        if nsView.isHidden == isVisible {
            nsView.isHidden = !isVisible
            // Ce qui est arrivé pendant qu'il était masqué n'a pas été peint.
            if isVisible { nsView.terminalView.needsDisplay = true }
        }
        // Le clavier suit la zone active, au moment où elle le devient — pas
        // à chaque mise à jour, ce qui l'arracherait à un champ de texte en
        // cours de saisie dans la barre latérale.
        let wantsKeyboard = isVisible && isFocused
        if wantsKeyboard, !context.coordinator.hadKeyboard {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView.terminalView)
            }
        }
        context.coordinator.hadKeyboard = wantsKeyboard
        guard context.coordinator.appliedStyle != style else { return }
        apply(style, to: nsView)
        context.coordinator.appliedStyle = style
    }

    /// Un thème change les seize couleurs ANSI, le fond, le texte, le curseur
    /// et la sélection d'un coup. On ne réapplique que si quelque chose a
    /// bougé : chaque changement de police recalcule la grille du terminal.
    private func apply(_ style: TerminalStyle, to container: PaddedTerminalView) {
        let terminal = container.terminalView
        let theme = style.theme

        container.inset = style.padding
        terminal.font = style.font
        terminal.lineSpacing = style.lineSpacing
        terminal.nativeBackgroundColor = theme.background.nsColor
        terminal.nativeForegroundColor = theme.foreground.nsColor
        terminal.caretColor = theme.cursor.nsColor
        terminal.selectedTextBackgroundColor = theme.selectionBackground.nsColor
        // SwiftTerm peint toujours le texte sélectionné dans cette couleur, noir
        // par défaut : sans couleur propre au thème, on garde celle du texte.
        terminal.selectedTextForegroundColor =
            (theme.selectionForeground ?? theme.foreground).nsColor
        terminal.installColors(theme.terminalColors)
        container.layer?.backgroundColor = theme.background.cgColor
        container.needsLayout = true
    }

    /// Ce qu'une demande de presse-papiers (OSC 52) peut y écrire.
    ///
    /// Un clic dans le vide d'un terminal fait entrer tmux en mode copie sur
    /// une sélection de blancs ; au relâchement, il la copie — vide — et la
    /// copie précédente disparaissait du presse-papiers du Mac. Une copie
    /// sans rien de visible n'est jamais voulue : elle est ignorée.
    static func clipboardText(from content: Data) -> String? {
        guard let text = String(data: content, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    static func dismantleNSView(_ nsView: PaddedTerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: TerminalSession
        /// Le dernier style posé, pour ne pas réappliquer à chaque redessin.
        var appliedStyle: TerminalStyle?
        private var cancellable: AnyCancellable?
        private weak var terminal: TerminalView?
        private var didStart = false
        /// Le terminal avait-il le clavier au dernier passage ?
        var hadKeyboard = false
        private var pendingResize: DispatchWorkItem?

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
            // Le premier redimensionnement est aussi le moment où l'on connaît
            // la vraie géométrie : c'est là qu'on lance le process.
            if !didStart, newRows > 0, newCols > 0 {
                didStart = true
                session.resize(rows: newRows, cols: newCols)
                session.start(rows: UInt16(newRows), cols: UInt16(newCols))
                return
            }
            // Glisser un séparateur change la taille à chaque pixel. L'hôte
            // n'en reçoit que la dernière : tmux redessinerait tout l'écran à
            // chaque fois, et par mosh, ça saccaderait.
            pendingResize?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.session.resize(rows: newRows, cols: newCols)
            }
            pendingResize = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
            guard let text = TerminalPane.clipboardText(from: content) else { return }
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
    var inset: CGFloat {
        didSet { needsLayout = true }
    }

    init(inset: CGFloat) {
        self.inset = inset
        self.terminalView = SelectableTerminalView(frame: .zero)
        super.init(frame: .zero)

        wantsLayer = true
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) inutilisé") }

    override func layout() {
        super.layout()
        terminalView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    override var acceptsFirstResponder: Bool { true }

    /// La marge appartient au terminal : une sélection qui y commence ne doit
    /// pas emporter la fenêtre.
    override var mouseDownCanMoveWindow: Bool { false }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(terminalView) ?? false
    }
}

/// La fenêtre se déplace par son fond (`isMovableByWindowBackground`), et une
/// vue non opaque compte comme du fond : c'est la valeur par défaut d'AppKit.
/// Le terminal l'est — sa couleur peut être translucide — si bien qu'un
/// cliquer-glisser pour sélectionner du texte déplaçait la fenêtre au lieu de
/// sélectionner. Il se déclare donc contenu, jamais fond.
///
/// Latch active la souris de tmux pour que la molette fasse défiler son
/// historique (voir `AppState.prepareSession`). Le cliquer-glisser lui revient
/// aussi : l'historique ne vit que dans tmux, et seule sa sélection sait y
/// descendre en défilant toute seule. Au relâchement, tmux copie dans le
/// presse-papiers du Mac par OSC 52.
///
/// ⌥ garde la sélection au terminal, celle d'un terminal ordinaire — ⇧ aussi,
/// par convention de SwiftTerm. Tant qu'elle est affichée, la souris n'est
/// plus rapportée : SwiftTerm efface sinon la sélection à chaque sortie
/// reçue, et sous une session qui redessine sans arrêt — le spinner de
/// Claude —, elle disparaissait avant qu'on ait pu la copier. tmux retrouve
/// la souris dès qu'elle tombe : clic, frappe, redimensionnement.
final class SelectableTerminalView: TerminalView {
    override var mouseDownCanMoveWindow: Bool { false }

    private var isPressed = false
    /// Prévient que ce terminal vient d'être cliqué : sa zone devient active.
    var onActivate: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        onActivate()
        isPressed = true
        // Le geste entier va au même endroit : on décide à l'appui, une fois.
        allowMouseReporting = !selectionActive && !event.modifierFlags.contains(.option)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        isPressed = false
        updateMouseReporting()
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        updateMouseReporting()
    }

    private func updateMouseReporting() {
        guard !isPressed else { return }
        allowMouseReporting = !selectionActive
    }

    /// ⌘⌫ efface la ligne, comme dans Terminal : AppKit le traduit en
    /// `deleteToBeginningOfLine:`, que SwiftTerm ignore. On envoie donc ^U,
    /// que le shell, readline et l'éditeur de ligne de zsh comprennent tous.
    /// `keyDown` n'étant pas surchargeable, la touche est prise au passage des
    /// équivalents clavier, qui précède le menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              Self.deletesLine(event) else {
            return super.performKeyEquivalent(with: event)
        }
        send([0x15])
        return true
    }

    /// ⌘⌫ seul : ⌘⌥⌫ ou ⌘⇧⌫ gardent leur sens.
    static func deletesLine(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return modifiers == .command && event.keyCode == 51 // kVK_Delete
    }
}
