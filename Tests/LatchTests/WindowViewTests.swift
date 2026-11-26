//
//  WindowViewTests.swift
//  LatchTests
//
//  Plusieurs fenêtres d'une même session à l'écran : la commande d'une vue,
//  et où va une fenêtre qu'on clique, qu'on glisse ou qu'on ouvre à côté.
//

import CoreGraphics
import Foundation
import XCTest

@testable import Latch

final class TmuxViewCommandTests: XCTestCase {

    private func shortcut(_ transport: Transport, host: String = "") -> Shortcut {
        var shortcut = Shortcut(
            name: "",
            connection: Connection(transport: transport, host: host, tmuxSession: "dev demande")
        )
        shortcut.connection.initialCommand = .claude
        shortcut.windows = [TmuxWindow(name: "logs", command: "tail -f log")]
        shortcut.connection.view = TmuxView(name: "dev demande~2", window: 3)
        return shortcut
    }

    /// Une vue rejoint le groupe, s'efface en se détachant, rallume la souris
    /// et arrive sur sa fenêtre — sans rien créer.
    func testAViewJoinsTheSessionGroup() throws {
        let command = try CommandBuilder.build(shortcut(.local))
        XCTAssertEqual(
            command,
            "tmux new -A -s 'dev demande~2' -t 'dev demande' "
                + "';' set-option -t 'dev demande~2' destroy-unattached on "
                + "';' set-option -t 'dev demande~2' mouse on "
                + "';' select-window -t 'dev demande~2:3'"
        )
        XCTAssertFalse(command.contains("claude"), "la commande initiale n'est pas rejouée")
        XCTAssertFalse(command.contains("new-window"), "aucune fenêtre n'est créée")
    }

    /// Par ssh, le `;` reste cité une fois passé le shell distant.
    func testAViewCrossesSSH() throws {
        let command = try CommandBuilder.build(shortcut(.ssh, host: "srv"))
        XCTAssertTrue(command.hasPrefix("ssh -t srv \"tmux new -A -s 'dev demande~2'"), command)
        XCTAssertTrue(command.contains("';' select-window"), command)
    }

    /// Le terminal laisse son nom de client en s'attachant, vue ou session.
    func testTheClientReportsItsName() throws {
        var view = shortcut(.local)
        view.connection.reportsClient = true
        XCTAssertTrue(try CommandBuilder.build(view).hasSuffix(
            "';' set-option -t 'dev demande~2' -F @latch-client '#{client_tty}'"))

        var plain = Shortcut(name: "", connection: Connection(transport: .local, host: "", tmuxSession: "api"))
        XCTAssertEqual(try CommandBuilder.build(plain), "tmux new -A -s api", "l'aperçu du builder ne change pas")
        plain.connection.reportsClient = true
        XCTAssertEqual(try CommandBuilder.build(plain),
                       "tmux new -A -s api ';' set-option -t api -F @latch-client '#{client_tty}'")
    }

    /// La vue n'est jamais persistée.
    func testAViewIsNotSaved() throws {
        let data = try JSONEncoder().encode(shortcut(.local))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("view"))
    }

    func testViewsAreRecognisedByName() {
        XCTAssertTrue(TmuxView.isView("api~2", of: "api"))
        XCTAssertTrue(TmuxView.isView("api~12", of: "api"))
        XCTAssertFalse(TmuxView.isView("api~", of: "api"))
        XCTAssertFalse(TmuxView.isView("api~x", of: "api"))
        XCTAssertFalse(TmuxView.isView("api2", of: "api"))
        XCTAssertFalse(TmuxView.isView("api", of: "api"))
    }
}

@MainActor
final class WindowPlacementTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState() -> (AppState, Shortcut) {
        let state = AppState(store: SessionStore(
            fileURL: directory.appendingPathComponent("shortcuts.json"),
            seedFromSSHConfig: false
        ))
        let shortcut = Shortcut(
            name: "", connection: Connection(transport: .local, host: "", tmuxSession: "api"))
        state.store.add(shortcut)
        return (state, shortcut)
    }

    /// Un terminal de la session, attaché à `session` (la session ou une vue).
    /// Il ne démarre jamais : aucune vue ne lui donne de taille.
    @discardableResult
    private func attach(
        _ state: AppState, _ shortcut: Shortcut, as session: String, in zone: Zone.ID? = nil
    ) -> TerminalSession {
        let tab = TerminalSession(name: "api", command: "true", shortcutID: shortcut.id,
                                  tmuxSession: session)
        state.add(tab, in: zone)
        return tab
    }

    /// Trois fenêtres ; `active` donne la fenêtre courante de chaque session.
    private func windows(_ state: AppState, active: [String: Int]) {
        var all: [String: [LiveWindow]] = [:]
        for (session, current) in active {
            all[session] = (0..<3).map {
                LiveWindow(session: session, index: $0, name: "w\($0)", isActive: $0 == current)
            }
        }
        state.setLiveWindowsForTesting(all, on: "")
    }

    private func sideBySide(_ state: AppState) -> (left: Zone.ID, right: Zone.ID) {
        state.apply(.sideBySide)
        let ids = state.layout.zones.map(\.id)
        state.zoneFrames = state.layout.geometry(in: CGRect(x: 0, y: 0, width: 1206, height: 400)).zones
        return (ids[0], ids[1])
    }

    /// Rien d'ouvert : on ouvre la session.
    func testAClosedSessionOpens() {
        let (state, shortcut) = makeState()
        XCTAssertEqual(state.placement(ofWindow: 1, of: shortcut, in: nil), .openSession)
    }

    /// Un clic sur une fenêtre déjà à l'écran active sa zone.
    func testAVisibleWindowFocusesItsZone() {
        let (state, shortcut) = makeState()
        let (left, right) = sideBySide(state)
        attach(state, shortcut, as: "api", in: left)
        state.focus(right)
        windows(state, active: ["api": 1])

        XCTAssertEqual(state.placement(ofWindow: 1, of: shortcut, in: nil), .focus(left))
        XCTAssertEqual(state.presence(ofWindow: LiveWindow(session: "api", index: 1, name: "", isActive: true),
                                      on: ""), .onScreen)
        state.closeAll()
    }

    /// Un clic sur une autre fenêtre : la zone de la session bascule dessus,
    /// sans ouvrir de vue — comme avant les zones.
    func testAClickSwitchesTheSessionsZone() {
        let (state, shortcut) = makeState()
        let (left, right) = sideBySide(state)
        let tab = attach(state, shortcut, as: "api", in: left)
        state.focus(right)
        windows(state, active: ["api": 0])

        XCTAssertEqual(state.placement(ofWindow: 2, of: shortcut, in: nil), .switchTab(tab.id))
        state.show(window: 2, of: shortcut, in: nil)
        XCTAssertEqual(state.focusedZoneID, left)
        XCTAssertEqual(state.activeWindow(of: tab)?.index, 2, "la bascule se voit sans attendre tmux")
        state.closeAll()
    }

    /// Une zone verrouillée garde sa fenêtre : la suivante demande une vue.
    func testALockedZoneKeepsItsWindow() {
        let (state, shortcut) = makeState()
        let (left, right) = sideBySide(state)
        attach(state, shortcut, as: "api", in: left)
        state.toggleLock(left)
        state.focus(right)
        windows(state, active: ["api": 0])

        XCTAssertEqual(state.placement(ofWindow: 2, of: shortcut, in: nil), .openView)
        state.closeAll()
    }

    /// Glisser une autre fenêtre sur une zone libre : une vue, la session
    /// restant où elle est.
    func testDroppingAnotherWindowBesideOpensAView() {
        let (state, shortcut) = makeState()
        let (left, right) = sideBySide(state)
        attach(state, shortcut, as: "api", in: left)
        windows(state, active: ["api": 0])

        XCTAssertEqual(state.placement(ofWindow: 2, of: shortcut, in: right), .openView)
        XCTAssertEqual(state.freshViewName(for: shortcut), "api~2")
        state.closeAll()
    }

    /// Une vue qui attend hors de l'écran sert avant d'en ouvrir une autre.
    func testAnIdleViewIsReused() {
        let (state, shortcut) = makeState()
        let (left, right) = sideBySide(state)
        attach(state, shortcut, as: "api", in: left)
        let view = attach(state, shortcut, as: "api~2", in: right)
        state.closeZone(right)
        windows(state, active: ["api": 0, "api~2": 1])
        let fresh = state.splitZone(left, axis: .horizontal)!

        XCTAssertEqual(state.placement(ofWindow: 2, of: shortcut, in: fresh), .switchTab(view.id))
        XCTAssertEqual(state.freshViewName(for: shortcut), "api~3", "api~2 est pris")
        state.closeAll()
    }

    /// Déposer sur la zone de la session la fait basculer, sans vue.
    func testDroppingOnTheSessionsZoneSwitchesIt() {
        let (state, shortcut) = makeState()
        let (left, _) = sideBySide(state)
        let tab = attach(state, shortcut, as: "api", in: left)
        windows(state, active: ["api": 0])

        XCTAssertEqual(state.placement(ofWindow: 2, of: shortcut, in: left), .switchTab(tab.id))
        state.closeAll()
    }

    /// Un terminal qui sort de l'écran ne dicte plus la taille de ses
    /// fenêtres ; il la retrouve en revenant.
    func testHiddenTerminalsIgnoreSize() async {
        let (state, shortcut) = makeState()
        let (left, right) = sideBySide(state)
        let base = attach(state, shortcut, as: "api", in: left)
        let view = attach(state, shortcut, as: "api~2", in: right)
        state.syncClientSizes()
        XCTAssertTrue(state.clientsIgnoringSize.isEmpty)

        state.toggleZoom(left)
        state.syncClientSizes()
        XCTAssertEqual(state.clientsIgnoringSize, [view.id])

        state.toggleZoom(left)
        state.closeZone(left)
        state.syncClientSizes()
        XCTAssertEqual(state.clientsIgnoringSize, [base.id])
        state.closeAll()
        state.syncClientSizes()
        XCTAssertTrue(state.clientsIgnoringSize.isEmpty)
    }

    /// Les vues ne sont pas des sessions oubliées.
    func testViewsAreNotOrphans() {
        let (state, _) = makeState()
        let now = Date()
        state.setLiveSessionsForTesting([
            LiveSession(name: "api", created: now, isAttached: true, windowCount: 3),
            LiveSession(name: "api~2", created: now, isAttached: true, windowCount: 3),
            LiveSession(name: "vieille", created: now, isAttached: false, windowCount: 1),
        ], on: "")
        XCTAssertEqual(state.orphanSessions(on: "").map(\.name), ["vieille"])
    }

    /// Un terminal terminé — la session perdue par l'hôte — se relance au
    /// clic sur son raccourci, au lieu de rester affiché mort.
    func testClickingAnEndedSessionRelaunchesIt() async {
        let (state, shortcut) = makeState()
        let tab = TerminalSession(name: "api", command: "exit 0", shortcutID: shortcut.id,
                                  tmuxSession: "api")
        state.add(tab)
        tab.start(rows: 24, cols: 80)
        let deadline = Date().addingTimeInterval(5)
        while !tab.hasEnded, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(tab.hasEnded, "le process est sorti")

        let reopened = await state.open(shortcut)
        XCTAssertTrue(reopened === tab, "le même terminal, pas un second")
        XCTAssertFalse(tab.hasEnded, "il est relancé")
        state.closeAll()
    }

    /// La fenêtre glissée porte le nom de sa session et le sien.
    func testAWindowItemIsNamedAfterBoth() {
        let (state, shortcut) = makeState()
        windows(state, active: ["api": 0])
        XCTAssertEqual(state.name(of: .window(shortcut.id, index: 2)), "api · 2 w2")
    }
}
