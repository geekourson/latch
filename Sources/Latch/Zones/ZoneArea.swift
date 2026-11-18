//
//  ZoneArea.swift
//  Latch
//
//  La place des terminaux, découpée en zones. Tout est positionné à la main à
//  partir de `ZoneLayout.geometry` : les terminaux doivent rester les mêmes
//  vues d'un découpage à l'autre — une vue de terminal détruite, c'est une
//  connexion coupée. Ils sont donc tous montés au même niveau, et c'est leur
//  cadre qui change.
//
//  Le placement passe par `.position`, qui déplace le cadre réel d'une vue
//  AppKit ; `.offset` ne déplacerait que son rendu, et les clics iraient à
//  l'ancienne place.
//
//  Trois couches : le décor des zones (cadre, barre de titre, zone vide), les
//  terminaux, puis ce qui se pose par-dessus (séparateurs, cible d'un dépôt).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ZoneArea: View {
    @EnvironmentObject private var app: AppState
    /// Le dernier cadre de chaque terminal affiché. Un terminal qui quitte
    /// l'écran le garde : le redimensionner pour rien ferait redessiner tmux.
    @State private var parked = ParkedFrames()

    static let headerHeight: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let geometry = app.zoneGeometry(in: bounds)
            let single = app.layout.isSingle || app.zoomedZoneID != nil

            ZStack(alignment: .topLeading) {
                Color(app.store.activeTheme.background.nsColor)

                ForEach(app.layout.zones.filter { geometry.zones[$0.id] != nil }) { zone in
                    let frame = geometry.zones[zone.id]!
                    ZoneChrome(zone: zone, single: single)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }

                ForEach(app.tabs) { session in
                    terminal(session, geometry: geometry, single: single)
                }

                ForEach(geometry.dividers, id: \.splitID) { divider in
                    DividerHandle(divider: divider)
                }

                if let hint = app.dropHint, let frame = geometry.zones[hint.zoneID] {
                    let target = Self.hintFrame(hint.region, in: frame)
                    TargetOutline(label: hint.label, refused: hint.region == .refused)
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.1), value: hint)
                }
            }
            .coordinateSpace(name: "zones")
            .onDrop(of: [UTType.plainText], delegate: ZoneDropDelegate(app: app))
            .onAppear { report(geometry, size: proxy.size) }
            .onChange(of: geometry) { _, new in report(new, size: proxy.size) }
        }
    }

    @ViewBuilder
    private func terminal(_ session: TerminalSession, geometry: ZoneLayout.Geometry, single: Bool) -> some View {
        let zone = app.layout.zone(showing: session.id)
        let zoneFrame = zone.flatMap { geometry.zones[$0.id] }
        let frame = zoneFrame.map { Self.contentFrame(of: $0, single: single) }
            ?? parked.frames[session.id]
            ?? Self.contentFrame(of: geometry.zones.values.first ?? .zero, single: single)
        let isVisible = zoneFrame != nil
        let _ = parked.remember(frame, for: session.id, when: isVisible)

        TerminalPane(
            session: session,
            style: app.store.terminalStyle,
            isVisible: isVisible,
            isFocused: zone?.id == app.focusedZoneID,
            onActivate: { [app] in
                guard let zone = app.layout.zone(showing: session.id) else { return }
                if app.focusedZoneID != zone.id { app.focus(zone.id) }
            }
        )
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
    }

    /// La part d'une zone réservée au terminal : sous la barre de titre, à
    /// l'intérieur du cadre. Seule, la zone n'a ni l'un ni l'autre.
    static func contentFrame(of zone: CGRect, single: Bool) -> CGRect {
        guard !single else { return zone }
        return CGRect(
            x: zone.minX + 1, y: zone.minY + headerHeight,
            width: max(0, zone.width - 2), height: max(0, zone.height - headerHeight - 1)
        )
    }

    static func hintFrame(_ region: DropRegion, in frame: CGRect) -> CGRect {
        switch region {
        case .center, .refused: return frame
        case .left: return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    private func report(_ geometry: ZoneLayout.Geometry, size: CGSize) {
        app.zoneFrames = geometry.zones
        app.zoneAreaSize = size
    }
}

/// Une boîte, pas un état SwiftUI : la retenir pendant le calcul de la vue ne
/// doit pas en provoquer un nouveau.
private final class ParkedFrames {
    var frames: [TerminalSession.ID: CGRect] = [:]

    func remember(_ frame: CGRect, for id: TerminalSession.ID, when visible: Bool) {
        if visible { frames[id] = frame }
    }
}

// MARK: - Décor d'une zone

private struct ZoneChrome: View {
    @EnvironmentObject private var app: AppState
    let zone: Zone
    /// Seule à l'écran : pas de cadre ni de barre de titre, la barre du haut
    /// de la fenêtre porte ses actions.
    let single: Bool

    private var session: TerminalSession? {
        zone.sessionID.flatMap { id in app.tabs.first { $0.id == id } }
    }

    private var isFocused: Bool { zone.id == app.focusedZoneID }

    var body: some View {
        VStack(spacing: 0) {
            if !single {
                ZoneHeader(zone: zone, session: session, isFocused: isFocused)
                    .frame(height: ZoneArea.headerHeight)
            }
            if session == nil {
                EmptyZone(zone: zone)
            } else {
                Spacer(minLength: 0)
            }
        }
        .background(Color(app.store.activeTheme.background.nsColor))
        .clipShape(RoundedRectangle(cornerRadius: single ? 0 : 6))
        .overlay {
            if !single {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.latchAccent : Color.latchBorder, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.focus(zone.id) }
    }
}

private struct ZoneHeader: View {
    @EnvironmentObject private var app: AppState
    let zone: Zone
    let session: TerminalSession?
    let isFocused: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let session {
                SessionLabel(session: session, isFocused: isFocused)
                if zone.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.latchAccent)
                        .help("Zone verrouillée")
                }
            } else {
                Text("zone vide")
                    .foregroundStyle(Color.latchTextFaint)
            }
            Spacer(minLength: 6)
            ZoneActions(zone: zone, showsLabels: false)
                .opacity(isHovering || isFocused ? 1 : 0.45)
        }
        .font(.system(size: 11))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.latchBorder).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let session {
                Button("Déconnecter") { app.close(tabID: session.id) }
            }
        }
    }
}

private struct SessionLabel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: TerminalSession
    let isFocused: Bool

    var body: some View {
        Circle()
            .fill(session.connection.dotColor)
            .frame(width: 5, height: 5)
            .help(session.connection.label)
        Text(session.title)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(isFocused ? Color.latchText : Color.latchTextDim)
            .lineLimit(1)
            .layoutPriority(1)
        // Deux zones peuvent montrer la même session : c'est la fenêtre qui
        // les distingue.
        if let window = app.activeWindow(of: session) {
            Text("\(window.index) \(window.name)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isFocused ? Color.latchTextDim : Color.latchTextFaint)
                .lineLimit(1)
        }
        Text(session.host.isEmpty ? localized("ce Mac") : session.host)
            .foregroundStyle(Color.latchTextFaint)
            .lineLimit(1)
    }
}

/// Les actions d'une zone, toujours visibles : verrouiller, couper à droite,
/// couper en dessous, agrandir, fermer. L'infobulle donne le raccourci.
struct ZoneActions: View {
    @EnvironmentObject private var app: AppState
    let zone: Zone
    /// Dans la barre du haut, la place permet d'écrire ce que fait chaque bouton.
    let showsLabels: Bool

    private var isZoomed: Bool { app.zoomedZoneID == zone.id }

    var body: some View {
        HStack(spacing: 1) {
            if zone.sessionID != nil {
                action(zone.isLocked ? "lock.fill" : "lock.open",
                       label: zone.isLocked ? "Verrouillée" : "Verrouiller",
                       help: zone.isLocked
                           ? localized("Déverrouiller la zone") + " — ⌥⌘L"
                           : localized("Verrouiller la zone : les clics de la barre latérale iront ailleurs") + " — ⌥⌘L",
                       highlighted: zone.isLocked) { app.toggleLock(zone.id) }
            }
            action("rectangle.split.2x1", label: "À droite",
                   help: localized("Couper à droite") + " — ⌘D") {
                app.splitZone(zone.id, axis: .horizontal)
            }
            action("rectangle.split.1x2", label: "En dessous",
                   help: localized("Couper en dessous") + " — ⇧⌘D") {
                app.splitZone(zone.id, axis: .vertical)
            }
            if !app.layout.isSingle {
                action(isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: isZoomed ? "Réduire" : "Agrandir",
                       help: (isZoomed ? localized("Revenir à la disposition") : localized("Agrandir")) + " — ⇧⌘↩") {
                    app.toggleZoom(zone.id)
                }
            }
            action("xmark", label: "Fermer",
                   help: localized("Fermer la zone : le terminal reste ouvert hors de l'écran") + " — ⌘W") {
                app.closeZone(zone.id)
            }
        }
    }

    private func action(
        _ symbol: String, label: LocalizedStringKey, help: String, highlighted: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                if showsLabels {
                    Text(label).font(.system(size: 10.5))
                }
            }
            .foregroundStyle(highlighted ? Color.latchAccent : Color.latchTextDim)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(ZoneButtonStyle())
        .help(help)
    }
}

private struct ZoneButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering || configuration.isPressed ? Color.latchBorderStrong : .clear)
            )
            .onHover { isHovering = $0 }
    }
}

// MARK: - Zone vide

/// Une zone vide n'est jamais un cul-de-sac : elle propose ce qu'elle peut
/// afficher, les terminaux déjà ouverts d'abord.
private struct EmptyZone: View {
    @EnvironmentObject private var app: AppState
    let zone: Zone

    private struct Candidate: Identifiable {
        let id: String
        let item: SidebarItem
        let name: String
        let host: String
        let isOpen: Bool
    }

    private var candidates: [Candidate] {
        let open = app.backgroundTabs.map { tab in
            Candidate(id: "tab-\(tab.id)", item: .tab(tab.id),
                      name: app.activeWindow(of: tab).map { "\(tab.title) · \($0.name)" } ?? tab.title,
                      host: tab.host, isOpen: true)
        }
        let closed = app.store.shortcuts
            .filter { shortcut in !app.tabs.contains { $0.shortcutID == shortcut.id } }
            .map { shortcut in
                Candidate(id: "shortcut-\(shortcut.id)", item: .shortcut(shortcut.id),
                          name: shortcut.displayName, host: shortcut.connection.host, isOpen: false)
            }
        return open + closed
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(spacing: 3) {
                    Text("Zone vide")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.latchText)
                    Text("Choisis ce qu'elle affiche, ou glisse une session depuis la barre latérale.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.latchTextFaint)
                        .multilineTextAlignment(.center)
                }
                if candidates.isEmpty {
                    Button("Nouvelle session") { app.newShortcut() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                VStack(spacing: 4) {
                    ForEach(candidates) { candidate in
                        Button {
                            app.show(candidate.item, in: zone.id)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(candidate.isOpen ? Color.latchSuccess : Color.latchTextFaint)
                                    .frame(width: 5, height: 5)
                                Text(candidate.name)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Color.latchText)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if candidate.isOpen {
                                    Text("ouverte")
                                        .foregroundStyle(Color.latchSuccess)
                                }
                                Text(candidate.host.isEmpty ? localized("ce Mac") : candidate.host)
                                    .foregroundStyle(Color.latchTextFaint)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.latchSurface))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.latchBorderStrong))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 280)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Séparateur

private struct DividerHandle: View {
    @EnvironmentObject private var app: AppState
    let divider: ZoneLayout.Divider

    @State private var isHovering = false
    @State private var isDragging = false

    private var isVertical: Bool { divider.axis == .horizontal }

    var body: some View {
        let frame = divider.frame
        // La poignée est une vue AppKit : une vue SwiftUI transparente compte
        // pour du fond de fenêtre, et la fenêtre se déplace par son fond — le
        // glisser emportait la fenêtre entière au lieu du séparateur.
        DividerGrip(
            isVertical: isVertical,
            onHover: { isHovering = $0 },
            onDrag: { location in
                isDragging = true
                // La poignée donne sa position dans son propre cadre.
                let container = divider.container
                let ratio = isVertical
                    ? ZoneLayout.ratio(at: frame.minX + location.x - container.minX, along: container.width)
                    : ZoneLayout.ratio(at: frame.minY + location.y - container.minY, along: container.height)
                app.setRatio(ratio, ofSplit: divider.splitID)
            },
            onEnd: { isDragging = false },
            onDoubleClick: { app.setRatio(0.5, ofSplit: divider.splitID) }
        )
        .overlay {
            Rectangle()
                .fill(isHovering || isDragging ? Color.latchAccent : Color.clear)
                .frame(width: isVertical ? 2 : nil, height: isVertical ? nil : 2)
                .allowsHitTesting(false)
        }
        .frame(width: frame.width, height: frame.height)
        .help("Glisser pour redimensionner · double-clic : parts égales")
        .position(x: frame.midX, y: frame.midY)
    }
}

/// Le séparateur côté AppKit : son curseur, son survol et son glisser. Les
/// coordonnées remises vont de haut en bas, comme celles de SwiftUI.
private struct DividerGrip: NSViewRepresentable {
    let isVertical: Bool
    let onHover: (Bool) -> Void
    let onDrag: (CGPoint) -> Void
    let onEnd: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {
        update(nsView)
    }

    private func update(_ view: GripView) {
        if view.isVertical != isVertical {
            view.isVertical = isVertical
            view.window?.invalidateCursorRects(for: view)
        }
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
    }

    final class GripView: NSView {
        var isVertical = true
        var onHover: (Bool) -> Void = { _ in }
        var onDrag: (CGPoint) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onDoubleClick: () -> Void = {}

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick() }
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag(convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) { onEnd() }
    }
}

// MARK: - Cible d'un dépôt

private struct TargetOutline: View {
    let label: String
    let refused: Bool

    var body: some View {
        let color = refused ? Color.latchTextFaint : Color.latchAccent
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(refused ? 0.18 : 0.08)))
            .overlay {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.latchText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.latchSurfaceHigh))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color))
                    .padding(8)
            }
            .padding(3)
    }
}

// MARK: - Dépôt

/// Le dépôt d'une ligne de la barre latérale. Ce qu'on glisse est connu de
/// l'app dès le début du geste (`AppState.draggedItem`) : le contenu du
/// presse-papiers de glisser ne sert qu'à faire accepter le geste.
private struct ZoneDropDelegate: DropDelegate {
    let app: AppState

    func validateDrop(info: DropInfo) -> Bool { app.draggedItem != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        app.updateDropHint(at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        app.dropHint = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        app.performDrop(at: info.location)
    }
}

// MARK: - Barre du haut

/// La bande sous les feux de circulation, à la place des onglets. À droite,
/// les dispositions ; à gauche, ce qui concerne la zone : ses actions quand
/// elle est seule à l'écran, le retour quand elle est agrandie.
struct ZoneTopBand: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 6) {
            if let zoomed = app.zoomedZoneID {
                let others = app.layout.zones.count - 1
                Text(others == 1
                     ? localized("Zone agrandie · 1 autre zone attend derrière.")
                     : String(format: localized("Zone agrandie · %d autres zones attendent derrière."), others))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextDim)
                    .lineLimit(1)
                Button {
                    app.toggleZoom(zoomed)
                } label: {
                    Label("Revenir à la disposition", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.latchAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.latchAccent))
                }
                .buttonStyle(.plain)
                .help("⇧⌘↩")
            } else if app.layout.isSingle, let zone = app.layout.zones.first {
                ZoneActions(zone: zone, showsLabels: true)
            }

            Spacer(minLength: 8)

            Text(app.layout.matchingPreset == nil && app.zoomedZoneID == nil ? "Disposition libre" : "Disposition")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.latchTextFaint)
                .lineLimit(1)
            ForEach(LayoutPreset.allCases) { preset in
                PresetButton(preset: preset)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 28)
    }
}

private struct PresetButton: View {
    @EnvironmentObject private var app: AppState
    let preset: LayoutPreset

    @State private var isHovering = false

    private var isCurrent: Bool {
        app.zoomedZoneID == nil && app.layout.matchingPreset == preset
    }

    var body: some View {
        let fits = app.presetFits(preset)
        Button {
            app.apply(preset)
        } label: {
            PresetIcon(preset: preset)
                .stroke(isCurrent ? Color.latchAccent : (isHovering && fits ? Color.latchTextDim : Color.latchTextFaint),
                        lineWidth: 1.2)
                .frame(width: CGFloat(10 + 4 * preset.columns), height: 11)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isCurrent || (isHovering && fits) ? Color.latchSurfaceHigh : .clear)
                )
                .contentShape(Rectangle())
                .opacity(fits ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(fits ? preset.title : preset.title + " · " + localized("fenêtre trop étroite"))
    }
}

/// Le dessin d'une disposition : un cadre et ses coupes.
private struct PresetIcon: Shape {
    let preset: LayoutPreset

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), cornerRadius: 1.5)
        let columns = preset.columns
        let rows = preset.zoneCount / max(1, columns)
        if columns > 1 {
            for index in 1..<columns {
                let x = rect.minX + rect.width * CGFloat(index) / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        }
        if rows > 1 {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        return path
    }
}

extension LayoutPreset {
    var title: String {
        switch self {
        case .single: return localized("Un seul terminal")
        case .sideBySide: return localized("Deux côte à côte")
        case .stacked: return localized("Deux superposés")
        case .grid2x2: return localized("Quatre (2 × 2)")
        case .grid3x2: return localized("Six (3 colonnes × 2 rangées)")
        case .grid4x2: return localized("Huit (4 colonnes × 2 rangées)")
        }
    }
}
