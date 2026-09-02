//
//  MCPServer.swift
//  Latch
//
//  SPEC §10, v0.4 : exposer l'app à Claude Code — ouvrir un panneau, lancer une
//  commande, afficher un fichier.
//
//  Claude Code tourne **sur le serveur** ; le serveur MCP tourne ici. Le pont,
//  c'est le tunnel qui existe déjà : la connexion ssh secondaire des hooks
//  porte un `-R`, et le serveur atteint donc Latch sur son propre localhost.
//  Tout passe par le tunnel, rien n'est exposé au réseau.
//
//  Un serveur HTTP local capable d'ouvrir des terminaux est une surface
//  d'attaque : il n'écoute que sur 127.0.0.1 et exige un jeton tiré au
//  lancement, sans lequel toute requête est refusée.
//

import Foundation
import Network

/// Ce que le serveur MCP sait demander à l'app.
@MainActor
protocol MCPHost: AnyObject {
    /// Les onglets ouverts : nom, hôte, état.
    func mcpListSessions() -> [[String: Any]]
    /// Ouvre un raccourci enregistré, par son nom.
    func mcpOpenSession(named name: String) async -> String
    /// Ouvre un onglet qui exécute une commande sur un hôte.
    func mcpRunCommand(_ command: String, on host: String?, named name: String?) -> String
    /// Ouvre un onglet qui affiche un fichier distant dans un pager.
    func mcpShowFile(_ path: String, on host: String?) -> String
}

@MainActor
final class MCPServer {

    /// Le port par défaut. Il est aussi celui du `-R` : les deux bouts doivent
    /// s'accorder, autant qu'il soit stable et documenté.
    static let defaultPort: UInt16 = 9339

    // Écrits une fois au lancement, lus depuis la file réseau : `nonisolated`
    // parce que l'acceptation d'une connexion n'a pas à passer par l'acteur
    // principal, seul le traitement de la requête en a besoin.
    nonisolated(unsafe) private(set) var port: UInt16 = MCPServer.defaultPort
    /// Tiré au lancement, jamais persisté : une nouvelle exécution de Latch
    /// invalide l'accès précédent.
    nonisolated(unsafe) private(set) var token: String = MCPServer.makeToken()

    weak var host: MCPHost?

    init(port: UInt16 = MCPServer.defaultPort) {
        self.port = port
    }

    private var listener: NWListener?
    nonisolated private let queue = DispatchQueue(label: "app.latch.mcp")

    nonisolated static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    var isRunning: Bool { listener != nil }

    /// La commande à lancer **sur le serveur** pour déclarer Latch à Claude Code.
    var claudeRegistrationCommand: String {
        "claude mcp add --transport http latch http://127.0.0.1:\(port)/mcp "
            + "--header \(ShellQuoting.singleQuoted("Authorization: Bearer \(token)"))"
    }

    /// L'option à ajouter à une connexion ssh pour que le serveur nous atteigne.
    var remoteForwardOption: String {
        "\(port):127.0.0.1:\(port)"
    }

    // MARK: - Cycle de vie

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // Localhost uniquement : le tunnel ssh se charge d'y amener le
            // serveur, rien n'a à venir du réseau.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
            )
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                connection.start(queue: self.queue)
                self.receive(on: connection, accumulated: Data())
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Latch: le serveur MCP n'a pas pu démarrer — \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP, le strict nécessaire

    nonisolated private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = HTTPRequest(buffer) {
                Task { @MainActor in
                    let response = await self.respond(to: request)
                    connection.send(
                        content: response,
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                }
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func respond(to request: HTTPRequest) async -> Data {
        guard request.bearerToken == token else {
            return HTTPRequest.response(status: "401 Unauthorized", json: ["error": "jeton invalide"])
        }
        guard request.method == "POST" else {
            return HTTPRequest.response(status: "405 Method Not Allowed", json: ["error": "POST attendu"])
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        else {
            return HTTPRequest.response(status: "400 Bad Request", json: ["error": "JSON illisible"])
        }

        // Une notification n'a pas d'identifiant et n'attend pas de réponse.
        guard let id = object["id"] else {
            return HTTPRequest.response(status: "202 Accepted", json: [:])
        }

        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        let result = await handle(method: method, params: params)

        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch result {
        case .success(let value): payload["result"] = value
        case .failure(let message):
            payload["error"] = ["code": -32601, "message": message]
        }
        return HTTPRequest.response(status: "200 OK", json: payload)
    }

    // MARK: - JSON-RPC

    private enum Outcome {
        case success([String: Any])
        case failure(String)
    }

    private func handle(method: String, params: [String: Any]) async -> Outcome {
        switch method {
        case "initialize":
            return .success([
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "latch", "version": "0.4.0"],
            ])

        case "tools/list":
            return .success(["tools": Self.toolDefinitions])

        case "tools/call":
            return await call(params: params)

        case "ping":
            return .success([:])

        default:
            return .failure("méthode inconnue : \(method)")
        }
    }

    private func call(params: [String: Any]) async -> Outcome {
        guard let host else { return .failure("Latch n'est pas prête.") }
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        func text(_ value: String) -> Outcome {
            .success(["content": [["type": "text", "text": value]]])
        }

        switch name {
        case "latch_list_sessions":
            let sessions = host.mcpListSessions()
            let data = (try? JSONSerialization.data(withJSONObject: sessions, options: [.prettyPrinted]))
                ?? Data()
            return text(String(decoding: data, as: UTF8.self))

        case "latch_open_session":
            guard let session = arguments["name"] as? String else {
                return .failure("Il manque « name ».")
            }
            return text(await host.mcpOpenSession(named: session))

        case "latch_run_command":
            guard let command = arguments["command"] as? String else {
                return .failure("Il manque « command ».")
            }
            return text(
                host.mcpRunCommand(
                    command,
                    on: arguments["host"] as? String,
                    named: arguments["name"] as? String
                )
            )

        case "latch_show_file":
            guard let path = arguments["path"] as? String else {
                return .failure("Il manque « path ».")
            }
            return text(host.mcpShowFile(path, on: arguments["host"] as? String))

        default:
            return .failure("outil inconnu : \(name)")
        }
    }

    /// Ce que Latch sait faire, décrit pour Claude Code. Rien qui touche au
    /// système : uniquement ouvrir des onglets dans l'app.
    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "latch_list_sessions",
            "description": "Liste les onglets ouverts dans Latch : nom, hôte, état de connexion.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "latch_open_session",
            "description": "Ouvre un raccourci Latch enregistré, par son nom, "
                + "et le met au premier plan s'il est déjà ouvert.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "Nom du raccourci."]],
                "required": ["name"],
            ],
        ],
        [
            "name": "latch_run_command",
            "description": "Ouvre un nouvel onglet Latch qui exécute une commande sur un hôte.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "Commande à exécuter."],
                    "host": ["type": "string", "description": "Alias ssh ; l'hôte courant par défaut."],
                    "name": ["type": "string", "description": "Titre de l'onglet."],
                ],
                "required": ["command"],
            ],
        ],
        [
            "name": "latch_show_file",
            "description": "Ouvre un onglet Latch affichant un fichier distant dans un pager.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Chemin du fichier sur l'hôte."],
                    "host": ["type": "string", "description": "Alias ssh ; l'hôte courant par défaut."],
                ],
                "required": ["path"],
            ],
        ],
    ]
}

// MARK: - Requête HTTP

/// Le minimum vital : une ligne de requête, des en-têtes, un corps de longueur
/// annoncée. On ne réécrit pas un serveur web, on répond à un client connu.
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        guard value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// `nil` tant que la requête n'est pas complète : l'appelant rappellera.
    init?(_ data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }

        let head = String(decoding: data[data.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1])

        headers = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let available = data[range.upperBound...]
        guard available.count >= expected else { return nil }
        body = Data(available.prefix(expected))
    }

    static func response(status: String, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = """
            HTTP/1.1 \(status)\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
        return Data(head.utf8) + body
    }
}
