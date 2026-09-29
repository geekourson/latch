//
//  TmuxAndMCPTests.swift
//  LatchTests
//
//  Les fenêtres tmux réelles et le serveur MCP (SPEC §12 v0.4, §10).
//

import Foundation
import Network
import XCTest

@testable import Latch

final class TmuxInspectorTests: XCTestCase {

    /// Le séparateur doit être improbable dans un nom de fenêtre. Une
    /// tabulation ne l'est pas assez : tmux en accepte dans `window_name`.
    private let separator = "\u{1F}"

    private func line(_ fields: String...) -> String {
        fields.joined(separator: separator)
    }

    func testParsesAWindowLine() throws {
        let window = try XCTUnwrap(
            TmuxInspector.parse(line: line("api", "2", "logs", "1", "journalctl"))
        )
        XCTAssertEqual(window.session, "api")
        XCTAssertEqual(window.index, 2)
        XCTAssertEqual(window.name, "logs")
        XCTAssertTrue(window.isActive)
        XCTAssertEqual(window.currentCommand, "journalctl")
        XCTAssertEqual(window.target, "api:2")
    }

    func testInactiveWindow() throws {
        let window = try XCTUnwrap(TmuxInspector.parse(line: line("api", "0", "bash", "0", "bash")))
        XCTAssertFalse(window.isActive)
    }

    /// Un nom de fenêtre avec des espaces ne doit pas décaler les champs.
    func testWindowNameWithSpaces() throws {
        let window = try XCTUnwrap(
            TmuxInspector.parse(line: line("mes notes", "1", "le journal", "0", "less"))
        )
        XCTAssertEqual(window.session, "mes notes")
        XCTAssertEqual(window.name, "le journal")
    }

    func testRefusesMalformedLines() {
        XCTAssertNil(TmuxInspector.parse(line: ""))
        XCTAssertNil(TmuxInspector.parse(line: "pas de séparateur"))
        XCTAssertNil(TmuxInspector.parse(line: line("api", "pas-un-nombre", "x", "0", "sh")))
        XCTAssertNil(TmuxInspector.parse(line: line("api", "1", "x")))
    }

    func testEmptyCommandBecomesNil() throws {
        let window = try XCTUnwrap(TmuxInspector.parse(line: line("api", "1", "x", "0", "  ")))
        XCTAssertNil(window.currentCommand)
    }

    /// Une seule connexion tenue ouverte, pas un ssh par sondage.
    func testWatchCommandLoopsOverOneConnection() {
        let command = TmuxInspector.watchCommand(every: 5)
        XCTAssertTrue(command.contains("while :;"))
        XCTAssertTrue(command.contains("sleep 5"))
        XCTAssertTrue(command.contains("tmux list-windows -a"))
        // Toutes les sessions, pas seulement la courante.
        XCTAssertTrue(command.contains("#{session_name}"))
        XCTAssertTrue(command.contains("#{window_active}"))
    }

    /// La commande de bascule doit citer sa cible : un nom de session peut
    /// contenir un espace.
    func testSelectingQuotesItsTarget() {
        let window = LiveWindow(session: "mes notes", index: 3, name: "x", isActive: false)
        XCTAssertEqual(window.target, "mes notes:3")
        XCTAssertEqual(ShellQuoting.quoted(window.target), "'mes notes:3'")
    }
}

final class HTTPRequestTests: XCTestCase {

    private func request(_ text: String) -> HTTPRequest? {
        HTTPRequest(Data(text.utf8))
    }

    func testParsesAPostWithABody() throws {
        let parsed = try XCTUnwrap(
            request(
                "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer abc123\r\nContent-Length: 2\r\n\r\n{}"
            )
        )
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/mcp")
        XCTAssertEqual(parsed.bearerToken, "abc123")
        XCTAssertEqual(String(decoding: parsed.body, as: UTF8.self), "{}")
    }

    /// Une requête coupée en deux paquets ne doit pas être traitée à moitié.
    func testIncompleteRequestIsNotAccepted() {
        XCTAssertNil(request("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n"))
        XCTAssertNil(request("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"))
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let parsed = try XCTUnwrap(
            request("POST / HTTP/1.1\r\nAUTHORIZATION: BEARER xyz\r\nContent-Length: 0\r\n\r\n")
        )
        XCTAssertEqual(parsed.bearerToken, "xyz")
    }

    func testMissingOrMalformedAuthorisationYieldsNoToken() throws {
        XCTAssertNil(try XCTUnwrap(request("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")).bearerToken)
        XCTAssertNil(
            try XCTUnwrap(
                request("GET / HTTP/1.1\r\nAuthorization: Basic abc\r\nContent-Length: 0\r\n\r\n")
            ).bearerToken
        )
    }

    func testResponseCarriesItsLength() throws {
        let data = HTTPRequest.response(status: "200 OK", json: ["ok": true])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("Content-Length: 11"))
        XCTAssertTrue(text.hasSuffix("{\"ok\":true}"))
    }
}

@MainActor
final class MCPServerTests: XCTestCase {

    /// Un serveur HTTP local capable d'ouvrir des terminaux est une surface
    /// d'attaque : le jeton n'est pas décoratif.
    func testTokenIsLongAndDifferentEveryTime() {
        let first = MCPServer.makeToken()
        let second = MCPServer.makeToken()
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
    }

    func testRegistrationCommandCarriesTheTokenAndTheLoopback() {
        let server = MCPServer()
        let command = server.claudeRegistrationCommand
        XCTAssertTrue(command.contains("claude mcp add --transport http latch"))
        XCTAssertTrue(command.contains("http://127.0.0.1:\(server.port)/mcp"))
        XCTAssertTrue(command.contains(server.token))
        // Le jeton est cité : il traverse un shell distant.
        XCTAssertTrue(command.contains("'Authorization: Bearer \(server.token)'"))
    }

    /// Le tunnel va du serveur vers le Mac, et n'écoute que sur la boucle
    /// locale des deux côtés.
    func testRemoteForwardStaysOnLoopback() {
        let server = MCPServer()
        XCTAssertEqual(server.remoteForwardOption, "\(server.port):127.0.0.1:\(server.port)")
    }

    /// Les quatre outils du §10 : ouvrir un panneau, lancer une commande,
    /// afficher un fichier — plus de quoi savoir ce qui est déjà ouvert.
    func testAdvertisesTheToolsTheSpecAsksFor() throws {
        let names = MCPServer.toolDefinitions.compactMap { $0["name"] as? String }
        XCTAssertEqual(
            Set(names),
            ["latch_list_sessions", "latch_open_session", "latch_run_command", "latch_show_file"]
        )

        for tool in MCPServer.toolDefinitions {
            XCTAssertNotNil(tool["description"] as? String, "\(tool["name"] ?? "?") sans description")
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
        }
    }

    /// Les définitions doivent survivre à la sérialisation : une valeur non
    /// représentable en JSON ferait échouer `tools/list` en silence.
    func testToolDefinitionsAreSerialisable() throws {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["tools": MCPServer.toolDefinitions]))
        XCTAssertNoThrow(
            try JSONSerialization.data(withJSONObject: ["tools": MCPServer.toolDefinitions])
        )
    }
}

@MainActor
final class MCPHostTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState() -> AppState {
        AppState(
            store: SessionStore(
                fileURL: directory.appendingPathComponent("shortcuts.json"),
                seedFromSSHConfig: false
            )
        )
    }

    func testListsOpenSessions() {
        let state = makeState()
        XCTAssertTrue(state.mcpListSessions().isEmpty)

        _ = state.mcpRunCommand("htop", on: "alex", named: "moniteur")
        let sessions = state.mcpListSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["name"] as? String, "moniteur")
        XCTAssertEqual(sessions[0]["host"] as? String, "alex")
        state.closeAll()
    }

    /// La commande passe par le même échappement que celles tapées à la main.
    func testRunCommandEscapesWhatClaudeSends() {
        let state = makeState()
        _ = state.mcpRunCommand(#"echo "l'erreur $HOME""#, on: "alex", named: nil)
        let command = try? XCTUnwrap(state.tabs.first?.command)
        XCTAssertEqual(
            command,
            #"ssh -t alex "echo \"l'erreur \$HOME\"""#
        )
        state.closeAll()
    }

    func testShowFileOpensAPagerAndNeverWrites() {
        let state = makeState()
        _ = state.mcpShowFile("/srv/api/main.py", on: "alex")
        let session = state.tabs.first
        XCTAssertEqual(session?.name, "main.py")
        XCTAssertEqual(session?.command.contains("less -R --"), true)
        XCTAssertEqual(session?.command.contains(">"), false, "rien ne doit écrire")
        state.closeAll()
    }

    /// Sans hôte ni session ouverte, on refuse en expliquant, plutôt que
    /// d'ouvrir un onglet vide.
    func testRefusesWithoutAHost() {
        let state = makeState()
        XCTAssertTrue(state.mcpRunCommand("ls", on: nil, named: nil).contains("Aucun hôte"))
        XCTAssertTrue(state.mcpShowFile("/etc/hosts", on: nil).contains("Aucun hôte"))
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testUnknownShortcutListsWhatExists() async {
        let state = makeState()
        state.store.add(
            Shortcut(
                name: "API · Claude",
                connection: Connection(transport: .local, host: "", tmuxSession: "api")
            )
        )
        let answer = await state.mcpOpenSession(named: "inexistant")
        XCTAssertTrue(answer.contains("API · Claude"), answer)
        XCTAssertTrue(state.tabs.isEmpty)
    }

    /// Retrouvé par son nom de raccourci comme par son nom de session tmux :
    /// Claude Code ne sait pas lequel l'utilisateur a en tête.
    func testFindsAShortcutByEitherName() async {
        let state = makeState()
        state.store.add(
            Shortcut(
                name: "API · Claude",
                connection: Connection(transport: .local, host: "", tmuxSession: "api")
            )
        )

        let bySession = await state.mcpOpenSession(named: "api")
        XCTAssertTrue(bySession.contains("ouvert"), bySession)
        XCTAssertEqual(state.tabs.count, 1)

        // Le même raccourci, demandé autrement : on remet au premier plan.
        let byName = await state.mcpOpenSession(named: "API · Claude")
        XCTAssertTrue(byName.contains("ouvert"), byName)
        XCTAssertEqual(state.tabs.count, 1)
        state.closeAll()
    }
}

// MARK: - Le serveur, pour de vrai

@MainActor
final class MCPServerIntegrationTests: XCTestCase {

    /// Un hôte de test : il note ce qu'on lui demande, sans rien ouvrir.
    private final class RecordingHost: MCPHost {
        var opened: [String] = []
        var commands: [String] = []

        func mcpListSessions() -> [[String: Any]] {
            [["name": "api", "host": "alex", "state": "latched on"]]
        }
        func mcpOpenSession(named name: String) async -> String {
            opened.append(name)
            return "Onglet « \(name) » ouvert."
        }
        func mcpRunCommand(_ command: String, on host: String?, named name: String?) -> String {
            commands.append(command)
            return "ok"
        }
        func mcpShowFile(_ path: String, on host: String?) -> String { "ok" }
    }

    private var server: MCPServer!
    private var recording: RecordingHost!

    override func setUp() async throws {
        // On laisse le système choisir : tirer un port au hasard dans la plage
        // éphémère finit par tomber sur un port déjà pris, et c'est ce qui est
        // arrivé.
        server = MCPServer(port: 0)
        recording = RecordingHost()
        server.host = recording
        server.start()

        let deadline = Date().addingTimeInterval(5)
        while server.port == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(server.port, 0, "le serveur n'a pas trouvé de port")
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func send(_ body: [String: Any], token: String? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token ?? server.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    func testInitializeAnnouncesTools() async throws {
        let (status, json) = try await send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:],
        ])
        XCTAssertEqual(status, 200)
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "latch")
    }

    func testToolsListReturnsTheFourTools() async throws {
        let (_, json) = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 4)
    }

    func testCallingAToolReachesTheApp() async throws {
        let (_, json) = try await send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "latch_open_session", "arguments": ["name": "api"]],
        ])
        let content = try XCTUnwrap((json["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String ?? "").contains("api"))
        XCTAssertEqual(recording.opened, ["api"])
    }

    func testMissingArgumentIsAnError() async throws {
        let (_, json) = try await send([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "latch_run_command", "arguments": [String: Any]()],
        ])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertTrue((error["message"] as? String ?? "").contains("command"))
        XCTAssertTrue(recording.commands.isEmpty)
    }

    func testUnknownMethodIsAnError() async throws {
        let (_, json) = try await send(["jsonrpc": "2.0", "id": 5, "method": "n'importe quoi"])
        XCTAssertNotNil(json["error"])
    }

    /// Sans le bon jeton, rien ne passe — c'est la seule chose qui protège un
    /// serveur capable d'ouvrir des terminaux.
    func testAWrongTokenIsRefused() async throws {
        let (status, _) = try await send(
            ["jsonrpc": "2.0", "id": 6, "method": "tools/list"], token: "faux"
        )
        XCTAssertEqual(status, 401)
        XCTAssertTrue(recording.opened.isEmpty)
    }
}

// MARK: - Branche git et latence (§9.1)

final class LiveRepositoryTests: XCTestCase {

    private let separator = "\u{1F}"

    func testParsesABranchWithChanges() throws {
        let repository = try XCTUnwrap(
            LiveRepository.parse(
                fields: ["api", "main", " 3 files changed, 12 insertions(+), 3 deletions(-)"]
            )
        )
        XCTAssertEqual(repository.session, "api")
        XCTAssertEqual(repository.branch, "main")
        XCTAssertEqual(repository.insertions, 12)
        XCTAssertEqual(repository.deletions, 3)
        XCTAssertTrue(repository.isDirty)
        XCTAssertEqual(repository.summary, "main +12 −3")
    }

    /// Un dépôt propre n'affiche que sa branche : ni « +0 » ni « −0 ».
    func testACleanRepositoryShowsOnlyItsBranch() throws {
        let repository = try XCTUnwrap(LiveRepository.parse(fields: ["api", "main", ""]))
        XCTAssertFalse(repository.isDirty)
        XCTAssertEqual(repository.summary, "main")
    }

    /// `git diff --shortstat` omet la moitié qui vaut zéro.
    func testHandlesInsertionsOnlyAndDeletionsOnly() throws {
        let added = try XCTUnwrap(
            LiveRepository.parse(fields: ["api", "main", " 1 file changed, 5 insertions(+)"])
        )
        XCTAssertEqual(added.insertions, 5)
        XCTAssertEqual(added.deletions, 0)
        XCTAssertEqual(added.summary, "main +5")

        let removed = try XCTUnwrap(
            LiveRepository.parse(fields: ["api", "main", " 1 file changed, 2 deletions(-)"])
        )
        XCTAssertEqual(removed.summary, "main −2")
    }

    /// Hors dépôt, la boucle distante ne rend rien : il n'y a pas de branche à
    /// inventer.
    func testNoBranchMeansNoRepository() {
        XCTAssertNil(LiveRepository.parse(fields: ["api", "", ""]))
        XCTAssertNil(LiveRepository.parse(fields: ["api"]))
    }

    func testDetachedHeadIsShownAsIs() throws {
        let repository = try XCTUnwrap(LiveRepository.parse(fields: ["api", "HEAD", ""]))
        XCTAssertEqual(repository.summary, "HEAD")
    }

    /// Sur le Mac, tmux est appelé par son chemin absolu : le PATH d'une app
    /// lancée depuis le Finder ne mène nulle part.
    func testTheLocalWatchCommandUsesAnAbsoluteTmux() {
        let command = TmuxInspector.watchCommand(tmux: "'/opt/homebrew/bin/tmux'")
        XCTAssertTrue(command.contains("'/opt/homebrew/bin/tmux' list-windows -a"), command)
        XCTAssertTrue(command.contains("'/opt/homebrew/bin/tmux' list-panes -a"), command)
        XCTAssertFalse(command.contains("; tmux "), "aucun appel par le seul nom")
    }

    /// La boucle distante ne doit ouvrir qu'une connexion pour tout : fenêtres
    /// et dépôts arrivent dans le même passage.
    func testTheWatchCommandAsksForBothInOneGo() {
        let command = TmuxInspector.watchCommand()
        XCTAssertTrue(command.contains("tmux list-windows -a"))
        XCTAssertTrue(command.contains("rev-parse --abbrev-ref HEAD"))
        XCTAssertTrue(command.contains("diff --shortstat"))
        // Le panneau actif de la fenêtre active, pas tous les panneaux.
        XCTAssertTrue(command.contains("#{&&:#{window_active},#{pane_active}}"))
        // Un chemin à espaces ne doit pas casser le découpage.
        XCTAssertTrue(command.contains("IFS='\(separator)' read -r s p"))
    }
}

@MainActor
final class LatencyProbeTests: XCTestCase {

    /// La boucle locale répond toujours, et vite.
    func testMeasuresTheLoopback() async throws {
        // Un port qui écoute à coup sûr : on en ouvre un pour l'occasion.
        let listener = try NWListener(using: .tcp, on: 0)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        defer { listener.cancel() }

        try await Task.sleep(for: .milliseconds(200))
        let port = try XCTUnwrap(listener.port?.rawValue)

        let measured = await LatencyProbe.measure(host: "127.0.0.1", port: port)
        XCTAssertNotNil(measured)
        XCTAssertLessThan(try XCTUnwrap(measured), .seconds(1))
    }

    /// Un hôte injoignable ne rend rien plutôt qu'un zéro qui mentirait.
    func testAnUnreachableHostYieldsNothing() async {
        let measured = await LatencyProbe.measure(
            host: "203.0.113.1", port: 22, timeout: .milliseconds(400)
        )
        XCTAssertNil(measured)
    }

    func testNothingMeasuredMeansNothingShown() {
        XCTAssertNil(LatencyProbe(host: "alex").label)
    }
}

// MARK: - Sessions sans raccourci

final class LiveSessionTests: XCTestCase {
    /// Ces tests comparent des textes français. La langue du système de la
    /// machine qui les exécute ne doit rien y changer : la CI tourne en
    /// anglais, et sans ça elle voyait passer les traductions.
    override func setUp() {
        super.setUp()
        Localization.apply(.french)
    }


    private let separator = "\u{1F}"

    private func session(created: Date = Date(), attached: Bool = false, windows: Int = 1)
        -> LiveSession
    {
        LiveSession(name: "api", created: created, isAttached: attached, windowCount: windows)
    }

    func testParsesASessionLine() throws {
        let parsed = try XCTUnwrap(
            LiveSession.parse(fields: ["atelier", "1756748321", "0", "3"])
        )
        XCTAssertEqual(parsed.name, "atelier")
        XCTAssertFalse(parsed.isAttached)
        XCTAssertEqual(parsed.windowCount, 3)
        XCTAssertEqual(parsed.created, Date(timeIntervalSince1970: 1_756_748_321))
    }

    func testRefusesIncompleteLines() {
        XCTAssertNil(LiveSession.parse(fields: ["api", "pas-un-nombre", "0", "1"]))
        XCTAssertNil(LiveSession.parse(fields: ["api", "1756748321", "0"]))
    }

    /// L'âge sert à décider quoi en faire : il doit se lire d'un coup d'œil.
    func testAgeReadsAtAGlance() {
        XCTAssertEqual(session(created: Date()).age, "à l'instant")
        XCTAssertEqual(session(created: Date(timeIntervalSinceNow: -600)).age, "il y a 10 min")
        XCTAssertEqual(session(created: Date(timeIntervalSinceNow: -7200)).age, "il y a 2 h")
        XCTAssertEqual(session(created: Date(timeIntervalSinceNow: -3 * 86400)).age, "il y a 3 j")
    }

    func testSummaryCountsWindows() {
        XCTAssertTrue(session(windows: 1).summary.hasPrefix("1 fenêtre,"))
        XCTAssertTrue(session(windows: 4).summary.hasPrefix("4 fenêtres,"))
    }

    /// La boucle distante relève aussi les sessions, dans le même passage.
    func testTheWatchCommandListsSessionsToo() {
        let command = TmuxInspector.watchCommand()
        XCTAssertTrue(command.contains("list-sessions -F"))
        XCTAssertTrue(command.contains("#{session_created}"))
        XCTAssertTrue(command.contains("#{session_windows}"))
    }
}

@MainActor
final class OrphanSessionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-orphans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState() -> AppState {
        AppState(
            store: SessionStore(
                fileURL: directory.appendingPathComponent("shortcuts.json"),
                seedFromSSHConfig: false
            )
        )
    }

    private func shortcut(session: String, host: String) -> Shortcut {
        Shortcut(
            name: session,
            connection: Connection(
                transport: host.isEmpty ? .local : .mosh, host: host, tmuxSession: session
            )
        )
    }

    /// Le cas vécu : un raccourci renommé laisse son ancienne session derrière
    /// lui, et une session ouverte à la main sur le serveur n'a jamais eu de
    /// raccourci. Les deux doivent se voir.
    func testASessionWithoutAShortcutIsAnOrphan() {
        let state = makeState()
        state.store.add(shortcut(session: "api", host: "alex"))

        XCTAssertEqual(state.orphanSessions(on: "alex"), [])

        state.setLiveSessionsForTesting(
            [
                LiveSession(name: "api", created: Date(), isAttached: true, windowCount: 1),
                LiveSession(name: "atelier", created: Date(), isAttached: false, windowCount: 1),
            ],
            on: "alex"
        )
        XCTAssertEqual(state.orphanSessions(on: "alex").map(\.name), ["atelier"])
    }

    /// Les raccourcis d'un autre hôte ne protègent pas une session ici.
    func testShortcutsOfAnotherHostDoNotCount() {
        let state = makeState()
        state.store.add(shortcut(session: "api", host: "ailleurs"))
        state.setLiveSessionsForTesting(
            [LiveSession(name: "api", created: Date(), isAttached: false, windowCount: 1)],
            on: "alex"
        )
        XCTAssertEqual(state.orphanSessions(on: "alex").map(\.name), ["api"])
    }

    /// Et les raccourcis locaux ne protègent que les sessions locales.
    func testLocalAndRemoteAreKeptApart() {
        let state = makeState()
        state.store.add(shortcut(session: "notes", host: ""))

        state.setLiveSessionsForTesting(
            [LiveSession(name: "notes", created: Date(), isAttached: false, windowCount: 1)],
            on: ""
        )
        XCTAssertEqual(state.orphanSessions(on: ""), [])

        state.setLiveSessionsForTesting(
            [LiveSession(name: "notes", created: Date(), isAttached: false, windowCount: 1)],
            on: "alex"
        )
        XCTAssertEqual(state.orphanSessions(on: "alex").map(\.name), ["notes"])
    }

    /// Adopter une orpheline pré-remplit le builder sur elle, sans rien créer
    /// tant qu'on n'a pas enregistré.
    func testAdoptingPrefillsTheBuilder() {
        let state = makeState()
        let orphan = LiveSession(name: "atelier", created: Date(), isAttached: false, windowCount: 2)
        state.adopt(orphan, on: "alex")

        XCTAssertEqual(state.editedShortcut?.connection.tmuxSession, "atelier")
        XCTAssertEqual(state.editedShortcut?.connection.host, "alex")
        XCTAssertTrue(state.store.shortcuts.isEmpty, "rien n'est créé avant l'enregistrement")
    }
}

// MARK: - Les fenêtres déclarées d'un raccourci

@MainActor
final class WindowReconciliationTests: XCTestCase {

    private func inspector() -> TmuxInspector { TmuxInspector(alias: "alex") }

    /// Ne rien faire quand la session n'a pas encore été vue : créer des
    /// fenêtres dans une session inconnue les mettrait n'importe où.
    func testWaitsUntilTheSessionIsKnown() {
        let inspector = inspector()
        // `windows` est vide : aucune session observée.
        inspector.reconcile(
            [TmuxWindow(name: "logs", command: "journalctl -f")], inSession: "api"
        )
        // Rien à vérifier d'autre que l'absence de plantage : la garde est là
        // pour que la commande ne parte pas.
        XCTAssertTrue(inspector.windows.isEmpty)
    }

    /// Une fenêtre sans nom ou sans commande n'est pas une fenêtre.
    func testIncompleteWindowsAreSkipped() {
        let declared = [
            TmuxWindow(name: "  ", command: "tail -f a"),
            TmuxWindow(name: "logs", command: "   "),
        ]
        for window in declared {
            XCTAssertTrue(
                window.name.trimmingCharacters(in: .whitespaces).isEmpty
                    || window.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    /// La cible d'une fenêtre reste citable : un nom de session peut contenir
    /// un espace.
    func testWindowTargetsSurviveQuoting() {
        let window = LiveWindow(session: "mes notes", index: 2, name: "logs", isActive: false)
        XCTAssertEqual(ShellQuoting.quoted(window.target), "'mes notes:2'")
    }
}

// MARK: - Reprendre une fenêtre créée à la main

@MainActor
final class RememberWindowTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-remember-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeState() -> AppState {
        let state = AppState(
            store: SessionStore(
                fileURL: directory.appendingPathComponent("shortcuts.json"),
                seedFromSSHConfig: false
            )
        )
        state.store.add(
            Shortcut(
                name: "API",
                connection: Connection(transport: .mosh, host: "alex", tmuxSession: "api")
            )
        )
        return state
    }

    private func window(name: String, command: String?) -> LiveWindow {
        LiveWindow(session: "api", index: 1, name: name, isActive: false, currentCommand: command)
    }

    /// Ce qui tourne dans la fenêtre devient la commande à rejouer.
    func testTheRunningCommandIsCarriedOver() {
        let state = makeState()
        state.rememberWindow(window(name: "logs", command: "journalctl"), on: "alex")

        let windows = try? XCTUnwrap(state.editedShortcut?.windows)
        XCTAssertEqual(windows?.map(\.name), ["logs"])
        XCTAssertEqual(windows?.first?.command, "journalctl")
    }

    /// Un shell nu n'est pas une commande à rejouer : le champ reste vide
    /// plutôt que d'inscrire « bash », que l'utilisateur devrait effacer.
    func testAPlainShellIsNotRecordedAsACommand() {
        let state = makeState()
        state.rememberWindow(window(name: "scratch", command: "bash"), on: "alex")
        XCTAssertEqual(state.editedShortcut?.windows.first?.command, "")
    }

    /// Rien n'est enregistré tant que le builder n'est pas validé : la fenêtre
    /// est proposée, pas imposée.
    func testNothingIsSavedUntilTheBuilderIsConfirmed() {
        let state = makeState()
        state.rememberWindow(window(name: "logs", command: "journalctl"), on: "alex")
        XCTAssertTrue(state.store.shortcuts.first?.windows.isEmpty ?? false)
    }

    /// Reprendre deux fois la même fenêtre ne la double pas.
    func testAWindowAlreadyDeclaredIsNotAddedTwice() {
        let state = makeState()
        state.rememberWindow(window(name: "logs", command: "journalctl"), on: "alex")
        state.save(try! XCTUnwrap(state.editedShortcut))

        state.rememberWindow(window(name: "logs", command: "journalctl"), on: "alex")
        XCTAssertEqual(state.editedShortcut?.windows.count, 1)
    }

    /// Une session sans raccourci n'a rien à quoi s'ajouter.
    func testASessionWithoutAShortcutOffersNothing() {
        let state = makeState()
        XCTAssertNil(state.shortcut(forSession: "atelier", on: "alex"))
        state.rememberWindow(
            LiveWindow(session: "atelier", index: 0, name: "x", isActive: false), on: "alex"
        )
        XCTAssertNil(state.editedShortcut)
    }
}
