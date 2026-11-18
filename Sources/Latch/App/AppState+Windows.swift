//
//  AppState+Windows.swift
//  Latch
//
//  Plusieurs fenêtres d'une même session tmux à l'écran, chacune dans sa zone.
//
//  Deux terminaux attachés à la même session montrent toujours la même
//  fenêtre : la fenêtre courante appartient à la session, pas au client. Une
//  zone qui veut une autre fenêtre reçoit donc une vue — une session groupée
//  avec la première (`TmuxView`), qui partage ses fenêtres et ses programmes
//  mais garde sa propre fenêtre courante.
//
//  Les vues ne s'ouvrent qu'à la demande, quand aucun terminal déjà ouvert ne
//  peut faire l'affaire : changer de fenêtre dans une zone qui montre déjà la
//  session coûte un `select-window`, une vue coûte une connexion.
//

import Foundation

/// Ce que demande l'affichage d'une fenêtre.
enum WindowPlacement: Equatable {
    /// Elle est déjà à l'écran : sa zone devient active.
    case focus(Zone.ID)
    /// Ce terminal de la session bascule dessus, et s'affiche si besoin.
    case switchTab(TerminalSession.ID)
    /// Aucun terminal ouvert sur la session : on l'ouvre, puis on bascule.
    case openSession
    /// Tous ses terminaux montrent autre chose, ailleurs : une vue de plus.
    case openView
}

extension AppState {

    /// Les vues demandent tmux, et un raccourci que Latch construit lui-même :
    /// une commande personnalisée ou le mode contrôle restent à une fenêtre
    /// à la fois, comme avant.
    func supportsViews(_ shortcut: Shortcut) -> Bool {
        !shortcut.isCustom && !shortcut.connection.controlMode
    }

    /// La fenêtre courante d'un terminal, telle que l'inspecteur la voit dans
    /// sa session — vue comprise.
    func activeWindow(of tab: TerminalSession) -> LiveWindow? {
        guard let session = tab.tmuxSession else { return nil }
        return liveWindows[tab.host]?[session]?.first(where: \.isActive)
    }

    /// Les zones qui montrent cette fenêtre de la session du raccourci.
    func zones(showingWindow index: Int, of shortcut: Shortcut) -> [Zone.ID] {
        tabs(of: shortcut).compactMap { tab in
            guard activeWindow(of: tab)?.index == index else { return nil }
            return layout.zone(showing: tab.id)?.id
        }
    }

    /// Où va une fenêtre. Dans une zone imposée (un dépôt, « à côté ») : le
    /// terminal de la session qui s'y trouve déjà, sinon celui qui la montre
    /// ailleurs — il se déplace —, sinon un terminal qui attend hors de
    /// l'écran. Sans zone (un clic) : la zone qui la montre ; sinon la zone
    /// de la session la plus récemment utilisée qui n'est pas verrouillée ;
    /// sinon un terminal hors de l'écran.
    func placement(ofWindow index: Int, of shortcut: Shortcut, in zoneID: Zone.ID?) -> WindowPlacement {
        let family = tabs(of: shortcut)
        guard !family.isEmpty else { return .openSession }
        let showing = family.filter { activeWindow(of: $0)?.index == index }

        if let zoneID {
            let zone = layout.zone(zoneID)
            if let here = family.first(where: { zone?.sessionID == $0.id }) { return .switchTab(here.id) }
            if let shown = showing.first(where: { layout.zone(showing: $0.id) != nil }) {
                return .switchTab(shown.id)
            }
        } else {
            if let shown = showing.compactMap({ layout.zone(showing: $0.id) }).first {
                return .focus(shown.id)
            }
            let recent = [focusedZoneID] + zoneHistory.reversed()
            let candidates = family.compactMap { layout.zone(showing: $0.id) }.filter { !$0.isLocked }
            if let zone = recent.lazy.compactMap({ id in candidates.first { $0.id == id } }).first
                ?? candidates.first,
               let tab = zone.sessionID {
                return .switchTab(tab)
            }
        }
        if let idle = family.first(where: { layout.zone(showing: $0.id) == nil }) {
            return .switchTab(idle.id)
        }
        return .openView
    }

    /// Affiche une fenêtre de la session d'un raccourci : dans une zone
    /// donnée, ou là où irait un clic de la barre latérale.
    func show(window index: Int, of shortcut: Shortcut, in zoneID: Zone.ID?) {
        switch placement(ofWindow: index, of: shortcut, in: zoneID) {
        case .focus(let zone):
            focus(zone)
        case .switchTab(let id):
            guard let tab = tabs.first(where: { $0.id == id }) else { return }
            show(tab.id, in: zoneID)
            selectWindow(index, in: tab)
        case .openSession:
            Task {
                guard let tab = await open(shortcut, into: zoneID) else { return }
                // tmux vient d'attacher : la fenêtre choisie est celle où
                // l'attachement a atterri, pas forcément celle qu'on visait.
                selectWindow(index, in: tab)
            }
        case .openView:
            let view = TmuxView(name: freshViewName(for: shortcut), window: index)
            Task { await open(shortcut, into: zoneID, view: view) }
        }
    }

    /// « api~2 », « api~3 »… le premier numéro qu'aucun terminal ni aucune
    /// session de l'hôte n'occupe.
    func freshViewName(for shortcut: Shortcut) -> String {
        let session = shortcut.connection.tmuxSession
        let host = shortcut.connection.host
        let taken = Set(tabs.compactMap(\.tmuxSession))
            .union((liveSessions[host] ?? []).map(\.name))
        var number = 2
        while taken.contains(TmuxView.name(for: session, number: number)) { number += 1 }
        return TmuxView.name(for: session, number: number)
    }

    /// Où se trouve une fenêtre à l'écran, pour la barre latérale.
    enum WindowPresence {
        case focused, onScreen, hidden
    }

    func presence(ofWindow window: LiveWindow, on host: String) -> WindowPresence {
        guard let shortcut = shortcut(forSession: window.session, on: host) else { return .hidden }
        let zones = zones(showingWindow: window.index, of: shortcut)
        if zones.contains(focusedZoneID) { return .focused }
        return zones.isEmpty ? .hidden : .onScreen
    }
}
