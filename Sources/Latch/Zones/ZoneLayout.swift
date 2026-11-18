//
//  ZoneLayout.swift
//  Latch
//
//  Plusieurs terminaux à l'écran. La zone de terminal se découpe en deux, et
//  chaque moitié peut se redécouper : un arbre binaire, dont les feuilles sont
//  les zones. Les dispositions toutes faites (deux, quatre, six, huit) n'en
//  sont que des formes particulières.
//
//  Ce fichier ne connaît ni SwiftUI ni les sessions : une zone désigne un
//  terminal par son identifiant, et la géométrie se calcule à partir d'un
//  rectangle. C'est ce qui permet de tout tester sans fenêtre.
//

import CoreGraphics
import Foundation

struct Zone: Identifiable, Equatable {
    let id: UUID
    /// Le terminal affiché, ou rien : une zone vide propose de quoi la remplir.
    var sessionID: UUID?
    /// Verrouillée, elle garde son terminal : un clic dans la barre latérale
    /// va remplir une autre zone.
    var isLocked = false

    init(id: UUID = UUID(), sessionID: UUID? = nil, isLocked: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.isLocked = isLocked
    }
}

enum SplitAxis: Equatable {
    /// Côte à côte : le séparateur est vertical.
    case horizontal
    /// Superposés : le séparateur est horizontal.
    case vertical
}

indirect enum ZoneNode: Equatable {
    case zone(Zone)
    /// `ratio` est la part du premier enfant.
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: ZoneNode, second: ZoneNode)

    var id: UUID {
        switch self {
        case .zone(let zone): return zone.id
        case .split(let id, _, _, _, _): return id
        }
    }
}

/// Les dispositions proposées en haut à droite de la fenêtre.
enum LayoutPreset: String, CaseIterable, Identifiable {
    case single, sideBySide, stacked, grid2x2, grid3x2, grid4x2

    var id: String { rawValue }

    var zoneCount: Int {
        switch self {
        case .single: return 1
        case .sideBySide, .stacked: return 2
        case .grid2x2: return 4
        case .grid3x2: return 6
        case .grid4x2: return 8
        }
    }

    /// Le nombre de colonnes, qui décide si la fenêtre est assez large.
    var columns: Int {
        switch self {
        case .single, .stacked: return 1
        case .sideBySide, .grid2x2: return 2
        case .grid3x2: return 3
        case .grid4x2: return 4
        }
    }
}

struct ZoneLayout: Equatable {
    var root: ZoneNode

    /// Une seule zone, vide ou non.
    init(sessionID: UUID? = nil) {
        root = .zone(Zone(sessionID: sessionID))
    }

    init(root: ZoneNode) {
        self.root = root
    }

    // MARK: - Lecture

    /// Les zones dans l'ordre de lecture : de gauche à droite, de haut en bas.
    var zones: [Zone] { Self.zones(in: root) }

    private static func zones(in node: ZoneNode) -> [Zone] {
        switch node {
        case .zone(let zone): return [zone]
        case .split(_, _, _, let first, let second): return zones(in: first) + zones(in: second)
        }
    }

    func zone(_ id: Zone.ID) -> Zone? {
        zones.first { $0.id == id }
    }

    /// La zone qui affiche ce terminal. Il n'y en a jamais deux : deux vues de
    /// tailles différentes sur la même session tmux se disputeraient sa taille.
    func zone(showing sessionID: UUID) -> Zone? {
        zones.first { $0.sessionID == sessionID }
    }

    var isSingle: Bool {
        if case .zone = root { return true }
        return false
    }

    // MARK: - Modification

    mutating func update(_ id: Zone.ID, _ change: (inout Zone) -> Void) {
        root = Self.mapping(root) { zone in
            guard zone.id == id else { return zone }
            var zone = zone
            change(&zone)
            return zone
        }
    }

    /// Retire ce terminal de l'écran : sa zone devient vide, et perd son verrou
    /// — il n'y a plus rien à protéger.
    mutating func clear(sessionID: UUID) {
        root = Self.mapping(root) { zone in
            guard zone.sessionID == sessionID else { return zone }
            return Zone(id: zone.id)
        }
    }

    /// Coupe une zone en deux. La nouvelle se place après (à droite, en
    /// dessous) ou avant (à gauche, au-dessus), et reçoit `sessionID`.
    @discardableResult
    mutating func split(
        _ id: Zone.ID, axis: SplitAxis, placingNewBefore: Bool = false, sessionID: UUID? = nil
    ) -> Zone.ID {
        let fresh = Zone(sessionID: sessionID)
        root = Self.replacing(id, in: root) { existing in
            .split(
                id: UUID(), axis: axis, ratio: 0.5,
                first: placingNewBefore ? .zone(fresh) : existing,
                second: placingNewBefore ? existing : .zone(fresh)
            )
        }
        return fresh.id
    }

    /// Ferme une zone : sa voisine récupère la place. La dernière zone ne
    /// disparaît pas, elle se vide. Rend la zone à activer ensuite.
    @discardableResult
    mutating func remove(_ id: Zone.ID) -> Zone.ID? {
        if case .zone(let only) = root {
            guard only.id == id else { return nil }
            root = .zone(Zone(id: only.id))
            return only.id
        }
        var survivor: Zone.ID?
        root = Self.removing(id, from: root, survivor: &survivor)
        return survivor
    }

    /// Le séparateur se garde à distance des bords : une zone écrasée à
    /// quelques pixels ne se rattrape plus à la souris.
    mutating func setRatio(_ ratio: Double, ofSplit id: UUID) {
        let clamped = min(0.85, max(0.15, ratio))
        root = Self.settingRatio(clamped, ofSplit: id, in: root)
    }

    // MARK: - Dispositions

    /// Construit une disposition remplie dans l'ordre de lecture. Les zones
    /// en trop restent vides ; les verrous suivent leur terminal.
    static func preset(_ preset: LayoutPreset, sessions: [UUID], locked: Set<UUID> = []) -> ZoneLayout {
        var queue = sessions[...]
        func next() -> ZoneNode {
            let id = queue.popFirst()
            return .zone(Zone(sessionID: id, isLocked: id.map(locked.contains) ?? false))
        }
        func row(_ count: Int) -> ZoneNode {
            // Chaque coupe donne au premier la part qui laisse des colonnes
            // égales : 1/3 puis 1/2 pour trois.
            let first = next()
            guard count > 1 else { return first }
            return .split(id: UUID(), axis: .horizontal, ratio: 1 / Double(count),
                          first: first, second: row(count - 1))
        }
        func grid(columns: Int) -> ZoneNode {
            let top = row(columns)
            let bottom = row(columns)
            return .split(id: UUID(), axis: .vertical, ratio: 0.5, first: top, second: bottom)
        }

        switch preset {
        case .single: return ZoneLayout(root: next())
        case .sideBySide: return ZoneLayout(root: row(2))
        case .stacked:
            let top = next()
            return ZoneLayout(root: .split(id: UUID(), axis: .vertical, ratio: 0.5, first: top, second: next()))
        case .grid2x2: return ZoneLayout(root: grid(columns: 2))
        case .grid3x2: return ZoneLayout(root: grid(columns: 3))
        case .grid4x2: return ZoneLayout(root: grid(columns: 4))
        }
    }

    /// La disposition toute faite que l'arbre reproduit, s'il en reproduit une
    /// — sinon c'est une disposition libre, faite à la main.
    var matchingPreset: LayoutPreset? {
        switch root {
        case .zone: return .single
        case .split(_, let axis, _, .zone, .zone):
            return axis == .horizontal ? .sideBySide : .stacked
        case .split(_, .vertical, _, let top, let bottom):
            let columns = Self.rowLength(top)
            guard columns >= 2, columns == Self.rowLength(bottom) else { return nil }
            return [2: .grid2x2, 3: .grid3x2, 4: .grid4x2][columns]
        default:
            return nil
        }
    }

    /// Le nombre de zones d'une rangée construite par `preset`, ou 0.
    private static func rowLength(_ node: ZoneNode) -> Int {
        switch node {
        case .zone: return 1
        case .split(_, .horizontal, _, .zone, let rest):
            let tail = rowLength(rest)
            return tail == 0 ? 0 : tail + 1
        default: return 0
        }
    }

    // MARK: - Géométrie

    struct Divider: Equatable {
        let splitID: UUID
        let axis: SplitAxis
        /// La bande qu'on attrape.
        let frame: CGRect
        /// Le rectangle que se partagent les deux enfants, pour convertir une
        /// position de souris en proportion.
        let container: CGRect
    }

    struct Geometry: Equatable {
        var zones: [Zone.ID: CGRect] = [:]
        var dividers: [Divider] = []
    }

    /// Les rectangles de chaque zone et de chaque séparateur. `gap` est
    /// l'épaisseur d'un séparateur.
    func geometry(in rect: CGRect, gap: CGFloat = ZoneLayout.gap) -> Geometry {
        var result = Geometry()
        Self.layout(root, in: rect, gap: gap, into: &result)
        return result
    }

    private static func layout(_ node: ZoneNode, in rect: CGRect, gap: CGFloat, into result: inout Geometry) {
        switch node {
        case .zone(let zone):
            result.zones[zone.id] = rect
        case .split(let id, let axis, let ratio, let first, let second):
            let firstRect, dividerRect, secondRect: CGRect
            switch axis {
            // La part s'applique à la longueur augmentée d'un séparateur : un
            // tiers de trois colonnes séparées par deux séparateurs fait alors
            // exactement une colonne.
            case .horizontal:
                let width = Self.firstLength(rect.width, ratio: ratio, gap: gap)
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
                dividerRect = CGRect(x: firstRect.maxX, y: rect.minY, width: gap, height: rect.height)
                secondRect = CGRect(x: dividerRect.maxX, y: rect.minY,
                                    width: max(0, rect.width - width - gap), height: rect.height)
            case .vertical:
                let height = Self.firstLength(rect.height, ratio: ratio, gap: gap)
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
                dividerRect = CGRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: gap)
                secondRect = CGRect(x: rect.minX, y: dividerRect.maxY,
                                    width: rect.width, height: max(0, rect.height - height - gap))
            }
            result.dividers.append(Divider(splitID: id, axis: axis, frame: dividerRect, container: rect))
            layout(first, in: firstRect, gap: gap, into: &result)
            layout(second, in: secondRect, gap: gap, into: &result)
        }
    }

    static let gap: CGFloat = 6

    private static func firstLength(_ total: CGFloat, ratio: Double, gap: CGFloat) -> CGFloat {
        min(max(0, total - gap), max(0, ((total + gap) * ratio - gap).rounded()))
    }

    /// La part que donne une position de souris sur un séparateur : l'inverse
    /// de `firstLength`, le séparateur centré sous le pointeur.
    static func ratio(at position: CGFloat, along total: CGFloat, gap: CGFloat = gap) -> Double {
        guard total + gap > 0 else { return 0.5 }
        return Double((position + gap / 2) / (total + gap))
    }

    enum Direction { case left, right, up, down }

    /// La zone voisine dans une direction : la plus proche dont le centre est
    /// de ce côté-là.
    static func neighbour(
        of id: Zone.ID, toward direction: Direction, in frames: [Zone.ID: CGRect]
    ) -> Zone.ID? {
        guard let origin = frames[id] else { return nil }
        let center = CGPoint(x: origin.midX, y: origin.midY)
        return frames
            .filter { candidate, frame in
                guard candidate != id else { return false }
                switch direction {
                case .left: return frame.midX < center.x
                case .right: return frame.midX > center.x
                case .up: return frame.midY < center.y
                case .down: return frame.midY > center.y
                }
            }
            .min { a, b in
                hypot(a.value.midX - center.x, a.value.midY - center.y)
                    < hypot(b.value.midX - center.x, b.value.midY - center.y)
            }?
            .key
    }

    // MARK: - Parcours

    private static func mapping(_ node: ZoneNode, _ transform: (Zone) -> Zone) -> ZoneNode {
        switch node {
        case .zone(let zone):
            return .zone(transform(zone))
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: mapping(first, transform), second: mapping(second, transform))
        }
    }

    private static func replacing(_ id: UUID, in node: ZoneNode, with build: (ZoneNode) -> ZoneNode) -> ZoneNode {
        if node.id == id { return build(node) }
        guard case .split(let splitID, let axis, let ratio, let first, let second) = node else { return node }
        return .split(id: splitID, axis: axis, ratio: ratio,
                      first: replacing(id, in: first, with: build),
                      second: replacing(id, in: second, with: build))
    }

    private static func removing(_ id: Zone.ID, from node: ZoneNode, survivor: inout Zone.ID?) -> ZoneNode {
        guard case .split(let splitID, let axis, let ratio, let first, let second) = node else { return node }
        if first.id == id {
            survivor = zones(in: second).first?.id
            return second
        }
        if second.id == id {
            survivor = zones(in: first).last?.id
            return first
        }
        return .split(id: splitID, axis: axis, ratio: ratio,
                      first: removing(id, from: first, survivor: &survivor),
                      second: removing(id, from: second, survivor: &survivor))
    }

    private static func settingRatio(_ ratio: Double, ofSplit id: UUID, in node: ZoneNode) -> ZoneNode {
        guard case .split(let splitID, let axis, let current, let first, let second) = node else { return node }
        return .split(id: splitID, axis: axis, ratio: splitID == id ? ratio : current,
                      first: settingRatio(ratio, ofSplit: id, in: first),
                      second: settingRatio(ratio, ofSplit: id, in: second))
    }
}
