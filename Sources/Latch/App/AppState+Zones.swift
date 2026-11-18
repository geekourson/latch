//
//  AppState+Zones.swift
//  Latch
//
//  Ce que font les zones : afficher un terminal, couper, fermer, agrandir,
//  verrouiller, appliquer une disposition, recevoir un glisser-déposer. L'arbre
//  lui-même vit dans `ZoneLayout` ; ici, on décide où va quoi.
//

import CoreGraphics
import Foundation

/// Une ligne de la barre latérale, telle qu'on la glisse.
enum SidebarItem: Equatable {
    case shortcut(Shortcut.ID)
    case tab(TerminalSession.ID)
    /// Une fenêtre tmux de la session d'un raccourci.
    case window(Shortcut.ID, index: Int)
}

/// Le côté d'une zone où tombe un dépôt.
enum DropRegion: Equatable {
    /// La session remplace ce que la zone affiche.
    case center
    case left, right, top, bottom
    /// Au centre d'une zone verrouillée : rien ne se passe.
    case refused
}

struct ZoneDropHint: Equatable {
    let zoneID: Zone.ID
    let region: DropRegion
    let label: String
}

/// Où irait un terminal qu'on affiche sans préciser de zone.
enum ZoneTarget: Equatable {
    /// Il est déjà à l'écran : sa zone devient active.
    case existing(Zone.ID)
    /// Il remplace ce que cette zone affiche.
    case replace(Zone.ID)
    /// Tout est verrouillé : cette zone se coupe pour lui faire place.
    case split(Zone.ID, SplitAxis)
}

extension AppState {

    /// En dessous, un terminal n'est plus lisible : la coupe est refusée.
    static let minimumZoneSize = CGSize(width: 260, height: 140)
    /// Une disposition n'est proposée que si chaque colonne garde cette largeur.
    static let minimumColumnWidth: CGFloat = 220

    var focusedZone: Zone? { layout.zone(focusedZoneID) }

    /// Les terminaux ouverts qu'aucune zone n'affiche.
    var backgroundTabs: [TerminalSession] {
        tabs.filter { layout.zone(showing: $0.id) == nil }
    }

    // MARK: - Afficher

    /// Où irait un terminal : sa zone s'il est déjà à l'écran ; sinon la zone
    /// active, sauf si elle est verrouillée — alors la dernière zone non
    /// verrouillée qu'on a utilisée. Si tout est verrouillé, la plus grande
    /// zone se coupe.
    func target(for sessionID: TerminalSession.ID?) -> ZoneTarget {
        if let sessionID, let existing = layout.zone(showing: sessionID) {
            return .existing(existing.id)
        }
        if let focused = focusedZone, !focused.isLocked { return .replace(focused.id) }
        let zones = layout.zones
        for id in zoneHistory.reversed() {
            if let zone = zones.first(where: { $0.id == id }), !zone.isLocked {
                return .replace(zone.id)
            }
        }
        if let free = zones.first(where: { !$0.isLocked }) { return .replace(free.id) }

        let largest = zones.max { area(of: $0.id) < area(of: $1.id) } ?? zones[0]
        let frame = zoneFrames[largest.id] ?? .zero
        return .split(largest.id, frame.width >= frame.height * 1.6 ? .horizontal : .vertical)
    }

    /// Affiche un terminal. Sans zone imposée, il va là où `target` le dit ;
    /// avec une zone, il y va — et quitte celle qu'il occupait, qui se ferme :
    /// un terminal n'est jamais à deux endroits.
    func show(_ sessionID: TerminalSession.ID, in zoneID: Zone.ID? = nil) {
        if let zoneID {
            if let current = layout.zone(showing: sessionID), current.id != zoneID {
                layout.remove(current.id)
            }
            guard layout.zone(zoneID) != nil else { return show(sessionID) }
            layout.update(zoneID) { $0.sessionID = sessionID }
            focus(zoneID)
            return
        }

        switch target(for: sessionID) {
        case .existing(let id):
            focus(id)
        case .replace(let id):
            layout.update(id) { $0.sessionID = sessionID }
            focus(id)
        case .split(let id, let axis):
            // Pas de contrôle de taille ici : on ne refuse pas d'afficher ce
            // qu'on vient d'ouvrir, quitte à faire une zone étroite.
            let fresh = layout.split(id, axis: axis, sessionID: sessionID)
            focus(fresh)
            showNotice(localized("Toutes les zones sont verrouillées : une nouvelle zone s'ouvre."))
        }
    }

    func focus(_ zoneID: Zone.ID) {
        guard layout.zone(zoneID) != nil else { return }
        if let zoomedZoneID, zoomedZoneID != zoneID { self.zoomedZoneID = nil }
        focusedZoneID = zoneID
        zoneHistory.removeAll { $0 == zoneID }
        zoneHistory.append(zoneID)
        if zoneHistory.count > 32 { zoneHistory.removeFirst() }
    }

    /// ⌥⌘ + flèche : la zone voisine dans cette direction.
    func focusNeighbour(_ direction: ZoneLayout.Direction) {
        guard zoomedZoneID == nil,
              let next = ZoneLayout.neighbour(of: focusedZoneID, toward: direction, in: zoneFrames)
        else { return }
        focus(next)
    }

    // MARK: - Couper, fermer, agrandir, verrouiller

    /// Coupe une zone. Refusé si les deux moitiés seraient trop petites pour
    /// un terminal lisible ; le message dit pourquoi.
    @discardableResult
    func splitZone(
        _ zoneID: Zone.ID, axis: SplitAxis, placingNewBefore: Bool = false,
        showing sessionID: TerminalSession.ID? = nil
    ) -> Zone.ID? {
        if let frame = zoneFrames[zoneID] {
            let minimum = Self.minimumZoneSize
            if axis == .horizontal, frame.width < minimum.width * 2 {
                showNotice(localized("Zone trop étroite pour être coupée en deux."))
                return nil
            }
            if axis == .vertical, frame.height < minimum.height * 2 {
                showNotice(localized("Zone trop basse pour être coupée en deux."))
                return nil
            }
        }
        if let sessionID, let current = layout.zone(showing: sessionID) {
            layout.remove(current.id)
        }
        zoomedZoneID = nil
        let fresh = layout.split(zoneID, axis: axis, placingNewBefore: placingNewBefore,
                                 sessionID: sessionID)
        focus(fresh)
        return fresh
    }

    func splitFocusedZone(_ axis: SplitAxis) {
        splitZone(focusedZoneID, axis: axis)
    }

    /// Ferme une zone. Son terminal reste connecté, hors de l'écran : la barre
    /// latérale le ramène d'un clic. « Déconnecter » est un geste à part.
    func closeZone(_ zoneID: Zone.ID) {
        zoomedZoneID = nil
        if let survivor = layout.remove(zoneID) {
            focus(survivor)
        }
        zoneHistory.removeAll { layout.zone($0) == nil }
    }

    func closeFocusedZone() {
        closeZone(focusedZoneID)
    }

    func toggleZoom(_ zoneID: Zone.ID) {
        guard !layout.isSingle else { return }
        zoomedZoneID = zoomedZoneID == zoneID ? nil : zoneID
        focus(zoneID)
    }

    func toggleZoomOfFocusedZone() {
        toggleZoom(focusedZoneID)
    }

    /// Une zone vide ne se verrouille pas : il n'y a rien à garder.
    func toggleLock(_ zoneID: Zone.ID) {
        guard let zone = layout.zone(zoneID), zone.sessionID != nil else { return }
        layout.update(zoneID) { $0.isLocked.toggle() }
        showNotice(zone.isLocked
            ? localized("Zone déverrouillée.")
            : localized("Zone verrouillée : les clics de la barre latérale iront ailleurs."))
    }

    func toggleLockOfFocusedZone() {
        toggleLock(focusedZoneID)
    }

    func setRatio(_ ratio: Double, ofSplit splitID: UUID) {
        layout.setRatio(ratio, ofSplit: splitID)
    }

    // MARK: - Dispositions

    func presetFits(_ preset: LayoutPreset) -> Bool {
        guard zoneAreaSize.width > 0 else { return true }
        return zoneAreaSize.width / CGFloat(preset.columns) >= Self.minimumColumnWidth
    }

    /// Applique une disposition toute faite. La zone active passe en premier,
    /// puis les autres terminaux à l'écran, puis ceux ouverts hors de l'écran :
    /// une grande disposition se remplit avec ce qui tourne déjà.
    func apply(_ preset: LayoutPreset) {
        guard presetFits(preset) else {
            showNotice(localized("Fenêtre trop étroite pour cette disposition."))
            return
        }
        let onScreen = layout.zones.compactMap(\.sessionID)
        let focused = focusedZone?.sessionID
        var ordered = focused.map { [$0] } ?? []
        ordered += onScreen.filter { $0 != focused }
        ordered += backgroundTabs.map(\.id).filter { !ordered.contains($0) }
        let locked = Set(layout.zones.filter(\.isLocked).compactMap(\.sessionID))

        layout = ZoneLayout.preset(preset, sessions: ordered, locked: locked)
        zoomedZoneID = nil
        zoneHistory = []
        focus(layout.zones[0].id)

        let hidden = ordered.count - preset.zoneCount
        if hidden == 1 {
            showNotice(localized("1 terminal reste ouvert hors de l'écran."))
        } else if hidden > 1 {
            showNotice(String(format: localized("%d terminaux restent ouverts hors de l'écran."), hidden))
        }
    }

    func resetLayout() {
        layout = ZoneLayout()
        zoomedZoneID = nil
        zoneHistory = []
        focus(layout.zones[0].id)
    }

    // MARK: - Barre latérale

    /// Le terminal qu'une ligne désigne, s'il est ouvert.
    ///
    /// Pour une fenêtre : le terminal qui la montre à l'écran — c'est lui qui
    /// se déplace quand on la glisse ailleurs.
    func session(for item: SidebarItem) -> TerminalSession? {
        switch item {
        case .tab(let id): return tabs.first { $0.id == id }
        case .shortcut(let id): return store.shortcut(id: id).flatMap(tab(for:))
        case .window(let id, let index):
            guard let shortcut = store.shortcut(id: id) else { return nil }
            return tabs(of: shortcut).first { tab in
                activeWindow(of: tab)?.index == index && layout.zone(showing: tab.id) != nil
            }
        }
    }

    func name(of item: SidebarItem) -> String {
        switch item {
        case .tab(let id): return tabs.first { $0.id == id }?.title ?? ""
        case .shortcut(let id): return store.shortcut(id: id)?.displayName ?? ""
        case .window(let id, let index):
            guard let shortcut = store.shortcut(id: id) else { return "" }
            let session = shortcut.connection.tmuxSession
            let window = liveWindows(on: shortcut.connection.host, session: session)
                .first { $0.index == index }
            return "\(shortcut.displayName) · \(index) \(window?.name ?? "")"
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Affiche une ligne de la barre latérale, dans une zone donnée ou là où
    /// irait un clic. Un raccourci fermé s'ouvre au passage.
    func show(_ item: SidebarItem, in zoneID: Zone.ID? = nil) {
        if case .window(let id, let index) = item {
            guard let shortcut = store.shortcut(id: id) else { return }
            return show(window: index, of: shortcut, in: zoneID)
        }
        if let session = session(for: item) { return show(session.id, in: zoneID) }
        guard case .shortcut(let id) = item, let shortcut = store.shortcut(id: id) else { return }
        Task { await open(shortcut, into: zoneID) }
    }

    /// « Ouvrir à côté » : la zone active se coupe à droite pour l'accueillir.
    func showBeside(_ item: SidebarItem) {
        if let session = session(for: item), let zone = layout.zone(showing: session.id) {
            focus(zone.id)
            showNotice(localized("Déjà à l'écran : sa zone est activée."))
            return
        }
        guard let fresh = splitZone(focusedZoneID, axis: .horizontal) else { return }
        show(item, in: fresh)
    }

    // MARK: - Glisser-déposer

    /// Le quart extérieur d'une zone coupe de ce côté ; le reste remplace.
    static let dropEdgeFraction: CGFloat = 0.28

    func dropRegion(at point: CGPoint, in zoneID: Zone.ID) -> DropRegion {
        guard let zone = layout.zone(zoneID), let frame = zoneFrames[zoneID] else { return .center }
        guard zone.sessionID != nil else { return .center }
        let center: DropRegion = zone.isLocked ? .refused : .center
        let distances: [(DropRegion, CGFloat)] = [
            (.left, (point.x - frame.minX) / frame.width),
            (.right, (frame.maxX - point.x) / frame.width),
            (.top, (point.y - frame.minY) / frame.height),
            (.bottom, (frame.maxY - point.y) / frame.height),
        ]
        guard let (edge, distance) = distances.min(by: { $0.1 < $1.1 }),
              distance <= Self.dropEdgeFraction else { return center }
        let minimum = Self.minimumZoneSize
        // Une coupe qui ferait des zones trop petites retombe sur le centre.
        switch edge {
        case .left, .right: return frame.width < minimum.width * 2 ? center : edge
        case .top, .bottom: return frame.height < minimum.height * 2 ? center : edge
        default: return center
        }
    }

    func zone(at point: CGPoint) -> Zone.ID? {
        if let zoomedZoneID { return zoomedZoneID }
        return zoneFrames.first { $0.value.contains(point) }?.key
    }

    func updateDropHint(at point: CGPoint) {
        guard let item = draggedItem, let zoneID = zone(at: point) else {
            dropHint = nil
            return
        }
        let region = dropRegion(at: point, in: zoneID)
        dropHint = ZoneDropHint(zoneID: zoneID, region: region, label: dropLabel(item, region, zoneID))
    }

    private func dropLabel(_ item: SidebarItem, _ region: DropRegion, _ zoneID: Zone.ID) -> String {
        let name = name(of: item)
        let session = session(for: item)
        let zone = layout.zone(zoneID)
        if let session, zone?.sessionID == session.id { return localized("Déjà dans cette zone") }
        switch region {
        case .refused:
            return localized("Zone verrouillée · dépose sur un bord pour la couper")
        case .center:
            if let shown = zone?.sessionID, let current = tabs.first(where: { $0.id == shown }) {
                return String(format: localized("Remplacer %@ par %@"), current.title, name)
            }
            return String(format: localized("Afficher %@ ici"), name)
        case .left, .right, .top, .bottom:
            let moving = session.flatMap { layout.zone(showing: $0.id) } != nil
            let format: String
            switch (region, moving) {
            case (.left, false): format = "Ouvrir %@ à gauche"
            case (.right, false): format = "Ouvrir %@ à droite"
            case (.top, false): format = "Ouvrir %@ au-dessus"
            case (.bottom, false): format = "Ouvrir %@ en dessous"
            case (.left, true): format = "Déplacer %@ à gauche"
            case (.right, true): format = "Déplacer %@ à droite"
            case (.top, true): format = "Déplacer %@ au-dessus"
            default: format = "Déplacer %@ en dessous"
            }
            return String(format: localized(format), name)
        }
    }

    /// Le dépôt : au centre, la session remplace ; sur un bord, la zone se
    /// coupe de ce côté. Une session déjà à l'écran est déplacée.
    func performDrop(at point: CGPoint) -> Bool {
        defer { dropHint = nil; draggedItem = nil }
        guard let item = draggedItem, let zoneID = zone(at: point) else { return false }
        let session = session(for: item)
        if let session, layout.zone(zoneID)?.sessionID == session.id { return false }

        switch dropRegion(at: point, in: zoneID) {
        case .refused:
            showNotice(localized("Zone verrouillée : déverrouille-la, ou dépose sur un bord."))
            return false
        case .center:
            show(item, in: zoneID)
        case let edge:
            let axis: SplitAxis = edge == .left || edge == .right ? .horizontal : .vertical
            let before = edge == .left || edge == .top
            guard let fresh = splitZone(zoneID, axis: axis, placingNewBefore: before,
                                        showing: session?.id) else { return false }
            if session == nil { show(item, in: fresh) }
        }
        return true
    }

    // MARK: - Géométrie

    private func area(of zoneID: Zone.ID) -> CGFloat {
        guard let frame = zoneFrames[zoneID] else { return 0 }
        return frame.width * frame.height
    }

    /// Ce que la vue dessine : toutes les zones, ou la seule agrandie.
    func zoneGeometry(in rect: CGRect) -> ZoneLayout.Geometry {
        if let zoomedZoneID, layout.zone(zoomedZoneID) != nil {
            return ZoneLayout.Geometry(zones: [zoomedZoneID: rect], dividers: [])
        }
        return layout.geometry(in: rect)
    }
}
