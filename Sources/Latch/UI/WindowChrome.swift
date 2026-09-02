//
//  WindowChrome.swift
//  Latch
//
//  SPEC §9.1 : « barre de titre transparente, feux de circulation atténués au
//  repos ».
//
//  macOS grise déjà les boutons quand la fenêtre perd le focus ; le §9.1 en
//  demande davantage — qu'ils s'effacent tant qu'on ne s'en occupe pas, et
//  reviennent au survol. C'est une vue sans pixel, posée là seulement pour
//  atteindre la `NSWindow` que SwiftUI ne donne pas autrement.
//

import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ChromeView: NSView {

    /// Assez visible pour qu'on sache où viser, assez discret pour disparaître.
    private static let restingAlpha: CGFloat = 0.45

    private var observers: [NSObjectProtocol] = []
    private var trackingArea: NSTrackingArea?

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            .map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateButtons() }
                }
            }

        installTracking()
        updateButtons()
    }

    /// Le survol de la zone des feux les rallume : on ne cherche pas un bouton
    /// qu'on ne voit plus.
    private func installTracking() {
        guard let contentView = window?.contentView else { return }
        if let trackingArea { contentView.removeTrackingArea(trackingArea) }

        let area = NSTrackingArea(
            rect: NSRect(x: 0, y: contentView.bounds.height - 40, width: 120, height: 40),
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setButtonAlpha(1) }
    override func mouseExited(with event: NSEvent) { updateButtons() }

    private func updateButtons() {
        setButtonAlpha(window?.isKeyWindow == true ? Self.restingAlpha : Self.restingAlpha * 0.6)
    }

    private func setButtonAlpha(_ alpha: CGFloat) {
        for kind in [
            NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton,
        ] {
            window?.standardWindowButton(kind)?.alphaValue = alpha
        }
    }
}
