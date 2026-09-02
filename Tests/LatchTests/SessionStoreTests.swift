//
//  SessionStoreTests.swift
//  LatchTests
//

import Foundation
import XCTest

@testable import Latch

@MainActor
final class SessionStoreTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("shortcuts.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SessionStore {
        SessionStore(fileURL: fileURL, seedFromSSHConfig: false)
    }

    private func sampleShortcut() -> Shortcut {
        Shortcut(
            name: "API · Claude",
            preflight: [Preflight(label: "VPN", command: "vpn up", failureIsFatal: false)],
            connection: Connection(
                transport: .mosh,
                host: "billy",
                tmuxSession: "api",
                workingDirectory: "~/api",
                initialCommand: .claudeContinue,
                extraArgs: "--model opus"
            ),
            windows: [TmuxWindow(name: "logs", command: "journalctl -fu api")]
        )
    }

    // MARK: - Aller-retour

    func testShortcutSurvivesARoundTrip() throws {
        let store = makeStore()
        let shortcut = sampleShortcut()
        store.add(shortcut)
        store.saveNow()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.shortcuts, [shortcut])
    }

    func testServerSurvivesARoundTrip() throws {
        let store = makeStore()
        var server = Server(name: "billy", sshAlias: "billy")
        server.probe = ProbeResult(
            hasTmux: true, tmuxVersion: "3.2a", hasMoshServer: false, hasClaude: false, osID: "ubuntu"
        )
        server.probedAt = Date()
        server.skipUpgradePrompt = true
        store.servers = [server]
        store.saveNow()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.servers.first?.probe?.tmuxVersion, "3.2a")
        XCTAssertEqual(reloaded.servers.first?.skipUpgradePrompt, true)
    }

    /// Le cas qui casse un `Codable` synthétisé si on ne l'a pas vérifié : une
    /// énumération à valeur associée.
    func testCustomInitialCommandSurvivesARoundTrip() throws {
        let store = makeStore()
        var shortcut = sampleShortcut()
        shortcut.connection.initialCommand = .custom("npm run dev")
        store.add(shortcut)
        store.saveNow()

        XCTAssertEqual(makeStore().shortcuts.first?.connection.initialCommand, .custom("npm run dev"))
    }

    // MARK: - Le fichier lui-même

    /// « Aucun secret dans ce fichier » (§4). On vérifie au moins qu'on n'y
    /// écrit rien qui ressemble à un mot de passe.
    func testFileIsPlainJSONWithoutSecrets() throws {
        let store = makeStore()
        store.add(sampleShortcut())
        store.saveNow()

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"version\""))
        for forbidden in ["password", "passphrase", "secret", "token"] {
            XCTAssertFalse(contents.lowercased().contains(forbidden), "trouvé « \(forbidden) »")
        }
    }

    func testMissingFileStartsEmptyWithoutError() {
        let store = makeStore()
        XCTAssertTrue(store.shortcuts.isEmpty)
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertNil(store.lastError)
    }

    /// Un fichier corrompu ne doit ni empêcher le démarrage ni être écrasé en
    /// silence : on préviendrait l'utilisateur trop tard.
    func testCorruptFileIsReportedAndPreserved() throws {
        try "ceci n'est pas du JSON".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = makeStore()
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.shortcuts.isEmpty)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "ceci n'est pas du JSON")
    }

    // MARK: - Rattachement aux serveurs

    func testShortcutsAreGroupedByServerAlias() {
        let store = makeStore()
        store.servers = [Server(name: "billy", sshAlias: "billy")]
        store.add(sampleShortcut())

        var elsewhere = sampleShortcut()
        elsewhere.id = UUID()
        elsewhere.connection.host = "autre"
        store.add(elsewhere)

        XCTAssertEqual(store.shortcuts(for: store.servers[0]).count, 1)
        XCTAssertEqual(store.unattachedShortcuts.map(\.connection.host), ["autre"])
    }

    func testServerIsCreatedOnDemand() {
        let store = makeStore()
        XCTAssertNil(store.server(forAlias: "neuf"))
        XCTAssertNotNil(store.server(forAlias: "neuf", creatingIfNeeded: true))
        XCTAssertEqual(store.servers.map(\.sshAlias), ["neuf"])
        // Deux appels ne créent pas deux serveurs.
        _ = store.server(forAlias: "neuf", creatingIfNeeded: true)
        XCTAssertEqual(store.servers.count, 1)
    }

    // MARK: - Cache de la sonde

    func testProbeExpiresAfterSevenDays() {
        var server = Server(name: "billy", sshAlias: "billy")
        XCTAssertTrue(server.probeIsStale, "jamais sondé")

        server.probedAt = Date()
        XCTAssertFalse(server.probeIsStale)

        server.probedAt = Date(timeIntervalSinceNow: -8 * 24 * 3600)
        XCTAssertTrue(server.probeIsStale)
    }

    func testInvalidatingTheProbeClearsTheCache() {
        let store = makeStore()
        var server = Server(name: "billy", sshAlias: "billy")
        server.probe = ProbeResult(hasTmux: true)
        server.probedAt = Date()
        store.servers = [server]

        store.invalidateProbe(serverID: server.id)
        XCTAssertNil(store.servers[0].probe)
        XCTAssertTrue(store.servers[0].probeIsStale)
    }
}

final class SSHConfigTests: XCTestCase {

    func testReadsHostAliasesInOrder() {
        let configuration = """
            # commentaire
            Host billy
                HostName 192.168.1.37
                User billy

            Host bastion prod
                HostName example.net
            """
        XCTAssertEqual(SSHConfig.hosts(in: configuration), ["billy", "bastion", "prod"])
    }

    /// `Host *` est un bloc de réglages par défaut, pas un serveur.
    func testIgnoresPatterns() {
        let configuration = """
            Host *
                ServerAliveInterval 60
            Host *.example.net
            Host !interdit
            Host billy
            """
        XCTAssertEqual(SSHConfig.hosts(in: configuration), ["billy"])
    }

    func testAcceptsEqualsAndMixedCase() {
        XCTAssertEqual(SSHConfig.hosts(in: "host=billy"), ["billy"])
        XCTAssertEqual(SSHConfig.hosts(in: "HOST billy"), ["billy"])
    }

    func testDeduplicates() {
        XCTAssertEqual(SSHConfig.hosts(in: "Host billy\nHost billy"), ["billy"])
    }

    func testEmptyConfigurationYieldsNothing() {
        XCTAssertEqual(SSHConfig.hosts(in: ""), [])
        XCTAssertEqual(SSHConfig.hosts(in: "# rien que des commentaires"), [])
    }
}
