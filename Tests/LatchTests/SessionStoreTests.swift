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

// MARK: - Compatibilité des fichiers entre versions

@MainActor
final class StoreCompatibilityTests: XCTestCase {

    private var fileURL: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("shortcuts.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ json: String) throws -> SessionStore {
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        return SessionStore(fileURL: fileURL, seedFromSSHConfig: false)
    }

    /// Le fichier exact qu'écrivait la v0.2, avant que `ProbeResult` gagne
    /// `offPathTools` et que le document gagne thèmes et réglages. Il a
    /// réellement cassé l'app une fois : la barre latérale s'est vidée.
    func testAFileFromAnEarlierVersionStillLoads() throws {
        let store = try load(
            """
            {
              "version": 1,
              "servers": [{
                "id": "11111111-1111-1111-1111-111111111111",
                "name": "billy",
                "sshAlias": "billy",
                "skipUpgradePrompt": false,
                "probedAt": 810037617.595638,
                "probe": {
                  "hasTmux": true, "tmuxVersion": "3.2a",
                  "hasMoshServer": false, "hasClaude": false, "osID": "ubuntu"
                }
              }],
              "shortcuts": [{
                "id": "22222222-2222-2222-2222-222222222222",
                "name": "API · Claude",
                "preflight": [],
                "windows": [],
                "connection": {
                  "transport": "mosh", "host": "billy", "tmuxSession": "api",
                  "initialCommand": {"shell": {}},
                  "keepShellOnExit": true, "controlMode": false
                }
              }]
            }
            """
        )

        XCTAssertNil(store.lastError, store.lastError ?? "")
        XCTAssertEqual(store.servers.map(\.name), ["billy"])
        XCTAssertEqual(store.servers.first?.probe?.tmuxVersion, "3.2a")
        XCTAssertEqual(store.servers.first?.probe?.offPathTools, [:])
        XCTAssertEqual(store.shortcuts.map(\.name), ["API · Claude"])
        XCTAssertEqual(store.preferences, Preferences())
        XCTAssertTrue(store.themes.isEmpty)
    }

    /// Le strict minimum : un raccourci n'a besoin que de sa connexion, un
    /// serveur que de son alias. Tout le reste doit se déduire.
    func testTheBareMinimumIsEnough() throws {
        let store = try load(
            """
            {
              "servers": [{"sshAlias": "billy"}],
              "shortcuts": [{"connection": {"host": "billy"}}]
            }
            """
        )
        XCTAssertNil(store.lastError, store.lastError ?? "")
        XCTAssertEqual(store.servers.first?.name, "billy", "le nom retombe sur l'alias")
        XCTAssertEqual(store.shortcuts.first?.connection.tmuxSession, "session")
        XCTAssertEqual(store.shortcuts.first?.connection.transport, .mosh)
        XCTAssertNotNil(store.shortcuts.first?.id, "un identifiant est fabriqué")
    }

    /// Une clé inconnue vient d'une version plus récente : on l'ignore plutôt
    /// que de refuser le fichier.
    func testUnknownKeysAreIgnored() throws {
        let store = try load(
            """
            {
              "version": 99,
              "servers": [{"sshAlias": "billy", "quelqueChoseDeFutur": true}],
              "shortcuts": [],
              "cequonNeConnaitPas": [1, 2, 3]
            }
            """
        )
        XCTAssertNil(store.lastError, store.lastError ?? "")
        XCTAssertEqual(store.servers.count, 1)
    }

    /// Ce qui n'a pas de repli sensé reste obligatoire : un raccourci sans
    /// connexion est cassé. Il est écarté **seul** — les autres survivent — et
    /// son éviction est annoncée plutôt que silencieuse.
    func testABrokenShortcutIsSkippedAloneAndReported() throws {
        let store = try load(
            """
            {
              "shortcuts": [
                {"name": "orphelin"},
                {"name": "bon", "connection": {"host": "billy", "tmuxSession": "api"}}
              ]
            }
            """
        )
        XCTAssertEqual(store.shortcuts.map(\.name), ["bon"])
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.lastError?.contains("1 entrée") ?? false, store.lastError ?? "")
    }

    /// Et le fichier reste intact tant que rien n'a été réenregistré : on ne
    /// détruit pas ce qu'on n'a pas su lire.
    func testTheFileIsNotRewrittenAfterSkipping() throws {
        let json = #"{"shortcuts": [{"name": "orphelin"}]}"#
        _ = try load(json)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), json)
    }
}
