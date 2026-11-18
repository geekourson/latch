//
//  ZoneTests.swift
//  LatchTests
//
//  Plusieurs terminaux à l'écran : l'arbre des zones, sa géométrie, et les
//  décisions de l'app — où va un clic, ce que garde un verrou, ce que fait un
//  dépôt.
//

import CoreGraphics
import Foundation
import XCTest

@testable import Latch

final class ZoneLayoutTests: XCTestCase {

    func testSplittingPlacesTheNewZoneOnTheRequestedSide() {
        var layout = ZoneLayout(sessionID: UUID())
        let original = layout.zones[0].id

        let right = layout.split(original, axis: .horizontal)
        XCTAssertEqual(layout.zones.map(\.id), [original, right])

        let left = layout.split(original, axis: .horizontal, placingNewBefore: true)
        XCTAssertEqual(layout.zones.map(\.id), [left, original, right])
    }

    /// La voisine récupère la place ; la dernière zone se vide sans disparaître.
    func testRemovingAZoneGivesItsPlaceToItsNeighbour() {
        var layout = ZoneLayout(sessionID: UUID())
        let first = layout.zones[0].id
        let second = layout.split(first, axis: .horizontal)

        XCTAssertEqual(layout.remove(second), first)
        XCTAssertTrue(layout.isSingle)

        XCTAssertEqual(layout.remove(first), first)
        XCTAssertTrue(layout.isSingle)
        XCTAssertNil(layout.zones[0].sessionID)
    }

    /// Fermer un terminal vide sa zone et lui retire son verrou.
    func testClearingASessionEmptiesItsZoneAndDropsTheLock() {
        let session = UUID()
        var layout = ZoneLayout(sessionID: session)
        let id = layout.zones[0].id
        layout.update(id) { $0.isLocked = true }

        layout.clear(sessionID: session)
        XCTAssertEqual(layout.zone(id), Zone(id: id))
    }

    func testTheRatioStaysAwayFromTheEdges() {
        var layout = ZoneLayout(sessionID: UUID())
        layout.split(layout.zones[0].id, axis: .horizontal)
        guard case .split(let id, _, _, _, _) = layout.root else { return XCTFail("pas de coupe") }

        layout.setRatio(0.01, ofSplit: id)
        guard case .split(_, _, let ratio, _, _) = layout.root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.15)
    }

    /// Glisser un séparateur puis relire sa position redonne la même part.
    func testTheDividerFollowsThePointer() {
        var layout = ZoneLayout(sessionID: UUID())
        layout.split(layout.zones[0].id, axis: .horizontal)
        guard case .split(let id, _, _, _, _) = layout.root else { return XCTFail() }
        layout.setRatio(ZoneLayout.ratio(at: 303, along: 1000), ofSplit: id)
        let divider = layout.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 500)).dividers[0]
        XCTAssertEqual(divider.frame.midX, 303, accuracy: 1)
    }

    /// Les colonnes d'une grille sont égales, séparateurs compris.
    func testGridColumnsAreEqual() {
        let layout = ZoneLayout.preset(.grid3x2, sessions: [])
        let geometry = layout.geometry(in: CGRect(x: 0, y: 0, width: 1212, height: 606), gap: 6)
        let widths = Set(layout.zones.compactMap { geometry.zones[$0.id]?.width })
        XCTAssertEqual(widths, [400])
        let heights = Set(layout.zones.compactMap { geometry.zones[$0.id]?.height })
        XCTAssertEqual(heights, [300])
        XCTAssertEqual(geometry.dividers.count, 5)
    }

    /// Une disposition se remplit dans l'ordre de lecture, et les verrous
    /// suivent leur terminal.
    func testPresetsFillInReadingOrderAndKeepLocks() {
        let sessions = (0..<5).map { _ in UUID() }
        let layout = ZoneLayout.preset(.grid4x2, sessions: sessions, locked: [sessions[2]])
        XCTAssertEqual(layout.zones.count, 8)
        XCTAssertEqual(Array(layout.zones.map(\.sessionID).prefix(5)), sessions)
        XCTAssertEqual(layout.zones.filter(\.isLocked).map(\.sessionID), [sessions[2]])
        XCTAssertTrue(layout.zones.suffix(3).allSatisfy { $0.sessionID == nil })
    }

    /// Le bouton allumé en haut à droite dit la disposition en cours ; après
    /// une coupe à la main, aucun ne l'est.
    func testTheCurrentPresetIsRecognised() {
        for preset in LayoutPreset.allCases {
            XCTAssertEqual(ZoneLayout.preset(preset, sessions: []).matchingPreset, preset)
        }
        var custom = ZoneLayout.preset(.sideBySide, sessions: [])
        custom.split(custom.zones[0].id, axis: .vertical)
        XCTAssertNil(custom.matchingPreset)
    }

    func testNeighbourFollowsTheDirection() {
        let layout = ZoneLayout.preset(.grid2x2, sessions: [])
        let frames = layout.geometry(in: CGRect(x: 0, y: 0, width: 800, height: 600)).zones
        let ids = layout.zones.map(\.id)  // haut-gauche, haut-droite, bas-gauche, bas-droite

        XCTAssertEqual(ZoneLayout.neighbour(of: ids[0], toward: .right, in: frames), ids[1])
        XCTAssertEqual(ZoneLayout.neighbour(of: ids[0], toward: .down, in: frames), ids[2])
        XCTAssertNil(ZoneLayout.neighbour(of: ids[0], toward: .left, in: frames))
    }
}

@MainActor
final class ZoneBehaviourTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-zones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState() -> AppState {
        AppState(store: SessionStore(
            fileURL: directory.appendingPathComponent("shortcuts.json"),
            seedFromSSHConfig: false
        ))
    }

    /// Deux zones côte à côte de 600 × 400, comme les mesurerait la vue.
    private func sideBySide(_ state: AppState) -> (left: Zone.ID, right: Zone.ID) {
        state.apply(.sideBySide)
        let ids = state.layout.zones.map(\.id)
        state.zoneFrames = state.layout.geometry(in: CGRect(x: 0, y: 0, width: 1206, height: 400)).zones
        return (ids[0], ids[1])
    }

    func testAShellOpensInTheFocusedZone() {
        let state = makeState()
        let shell = state.openLocalShell(named: "a")
        XCTAssertEqual(state.layout.zones[0].sessionID, shell.id)
        XCTAssertEqual(state.selectedTab?.id, shell.id)
        state.closeAll()
    }

    /// Un terminal déjà à l'écran n'est jamais dupliqué : sa zone devient active.
    func testShowingAVisibleTerminalFocusesItsZone() {
        let state = makeState()
        let (left, right) = sideBySide(state)
        let a = state.openLocalShell(named: "a")
        state.focus(right)
        let b = state.openLocalShell(named: "b")

        state.show(a.id)
        XCTAssertEqual(state.focusedZoneID, left)
        XCTAssertEqual(state.layout.zones.compactMap(\.sessionID), [a.id, b.id])
        state.closeAll()
    }

    /// Le cœur du verrou : la zone active est verrouillée, le terminal va dans
    /// la dernière zone non verrouillée qu'on a utilisée.
    func testALockedZoneSendsTheNextTerminalElsewhere() {
        let state = makeState()
        let (left, right) = sideBySide(state)
        state.focus(left)
        let a = state.openLocalShell(named: "a")
        state.focus(right)
        let b = state.openLocalShell(named: "b")
        state.toggleLock(right)

        let c = state.openLocalShell(named: "c")
        XCTAssertEqual(state.layout.zone(left)?.sessionID, c.id)
        XCTAssertEqual(state.layout.zone(right)?.sessionID, b.id, "la zone verrouillée garde son terminal")
        XCTAssertTrue(state.backgroundTabs.contains { $0.id == a.id }, "a reste ouvert hors de l'écran")
        state.closeAll()
    }

    /// Tout verrouillé : la plus grande zone se coupe pour faire place.
    func testWhenEverythingIsLockedANewZoneOpens() {
        let state = makeState()
        let (left, right) = sideBySide(state)
        state.focus(left)
        _ = state.openLocalShell(named: "a")
        state.focus(right)
        _ = state.openLocalShell(named: "b")
        state.toggleLock(left)
        state.toggleLock(right)

        let c = state.openLocalShell(named: "c")
        XCTAssertEqual(state.layout.zones.count, 3)
        XCTAssertEqual(state.focusedZone?.sessionID, c.id)
        state.closeAll()
    }

    /// Fermer une zone ne déconnecte rien ; déconnecter vide la zone.
    func testClosingAZoneKeepsTheTerminalOpen() {
        let state = makeState()
        let (_, right) = sideBySide(state)
        state.focus(right)
        let b = state.openLocalShell(named: "b")

        state.closeZone(right)
        XCTAssertTrue(state.layout.isSingle)
        XCTAssertTrue(state.tabs.contains { $0.id == b.id })

        state.show(b.id)
        state.close(tabID: b.id)
        XCTAssertNil(state.layout.zone(showing: b.id))
        XCTAssertFalse(state.tabs.contains { $0.id == b.id })
    }

    /// Une coupe qui ferait des zones illisibles est refusée.
    func testASplitThatWouldBeTooNarrowIsRefused() {
        let state = makeState()
        let zone = state.layout.zones[0].id
        state.zoneFrames = [zone: CGRect(x: 0, y: 0, width: 400, height: 600)]
        XCTAssertNil(state.splitZone(zone, axis: .horizontal))
        XCTAssertNotNil(state.splitZone(zone, axis: .vertical))
    }

    /// Une disposition se remplit avec ce qui tourne déjà, la zone active en tête.
    func testAPresetFillsWithOpenTerminalsFocusedFirst() {
        let state = makeState()
        let a = state.openLocalShell(named: "a")
        let b = state.openLocalShell(named: "b")  // remplace a, qui passe en arrière-plan
        state.apply(.grid2x2)
        XCTAssertEqual(state.layout.zones.map(\.sessionID), [b.id, a.id, nil, nil])
        state.closeAll()
    }

    /// Au centre, le dépôt remplace ; sur un bord, il coupe ; au centre d'une
    /// zone verrouillée, il est refusé.
    func testDropRegions() {
        let state = makeState()
        let (left, _) = sideBySide(state)
        state.focus(left)
        _ = state.openLocalShell(named: "a")
        let frame = state.zoneFrames[left]!  // 600 × 400
        XCTAssertEqual(frame.size, CGSize(width: 600, height: 400))

        XCTAssertEqual(state.dropRegion(at: CGPoint(x: frame.midX, y: frame.midY), in: left), .center)
        XCTAssertEqual(state.dropRegion(at: CGPoint(x: frame.maxX - 20, y: frame.midY), in: left), .right)
        XCTAssertEqual(state.dropRegion(at: CGPoint(x: frame.midX, y: frame.minY + 10), in: left), .top)

        // Trop étroite pour deux zones de 260 : le bord retombe sur le centre.
        state.zoneFrames[left] = CGRect(x: 0, y: 0, width: 400, height: 400)
        XCTAssertEqual(state.dropRegion(at: CGPoint(x: 390, y: 200), in: left), .center)

        state.toggleLock(left)
        XCTAssertEqual(state.dropRegion(at: CGPoint(x: frame.midX, y: frame.midY), in: left), .refused)
        state.closeAll()
    }

    /// Glisser un terminal déjà à l'écran sur le bord d'une autre zone le
    /// déplace : son ancienne zone se referme.
    func testDroppingAVisibleTerminalMovesIt() {
        let state = makeState()
        state.apply(.grid2x2)
        state.zoneFrames = state.layout.geometry(in: CGRect(x: 0, y: 0, width: 1206, height: 806)).zones
        let ids = state.layout.zones.map(\.id)
        state.focus(ids[0])
        let a = state.openLocalShell(named: "a")
        state.focus(ids[3])
        _ = state.openLocalShell(named: "d")

        state.draggedItem = .tab(a.id)
        let target = state.zoneFrames[ids[3]]!
        XCTAssertTrue(state.performDrop(at: CGPoint(x: target.maxX - 10, y: target.midY)))

        XCTAssertEqual(state.layout.zones.filter { $0.sessionID == a.id }.count, 1)
        XCTAssertNil(state.layout.zone(ids[0]), "l'ancienne zone de a s'est refermée")
        XCTAssertEqual(state.layout.zones.count, 4)
        XCTAssertNil(state.draggedItem)
        state.closeAll()
    }
}
