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

        _ = state.mcpRunCommand("htop", on: "billy", named: "moniteur")
        let sessions = state.mcpListSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["name"] as? String, "moniteur")
        XCTAssertEqual(sessions[0]["host"] as? String, "billy")
        state.closeAll()
    }

    /// La commande passe par le même échappement que celles tapées à la main.
    func testRunCommandEscapesWhatClaudeSends() {
        let state = makeState()
        _ = state.mcpRunCommand(#"echo "l'erreur $HOME""#, on: "billy", named: nil)
        let command = try? XCTUnwrap(state.tabs.first?.command)
        XCTAssertEqual(
            command,
            #"ssh -t billy "echo \"l'erreur \$HOME\"""#
        )
        state.closeAll()
    }

    func testShowFileOpensAPagerAndNeverWrites() {
        let state = makeState()
        _ = state.mcpShowFile("/srv/api/main.py", on: "billy")
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
            [["name": "api", "host": "billy", "state": "latched on"]]
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
        // Un port au hasard dans la plage éphémère : la suite ne doit pas
        // échouer parce qu'une instance de Latch tourne à côté.
        server = MCPServer(port: UInt16.random(in: 49152...65000))
        recording = RecordingHost()
        server.host = recording
        server.start()
        try await Task.sleep(for: .milliseconds(150))
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
        XCTAssertNil(LatencyProbe(host: "billy").label)
    }
}
