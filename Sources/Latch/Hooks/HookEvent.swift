//
//  HookEvent.swift
//  Latch
//
//  SPEC §10. Claude Code tourne **sur le serveur**, pas sur le Mac : tout ce
//  que Latch en sait passe par les hooks, écrits ligne par ligne dans un
//  fichier que l'app suit par une connexion ssh secondaire.
//

import Foundation

/// Un événement de hook, tel que Claude Code l'envoie sur l'entrée standard.
///
/// Le §10 cite `SessionStart`, `PreToolUse`, `PostToolUse` et `SessionEnd`.
/// Deux autres sont indispensables à ce que le même paragraphe demande —
/// « notification quand une tâche se termine ou qu'une permission est
/// attendue » : `Stop` marque la fin d'une réponse, et `Notification` porte le
/// motif `permission_prompt`.
struct HookEvent: Equatable {

    enum Kind: String, Equatable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case notification = "Notification"
        case unknown

        init(rawEvent: String) {
            self = Kind(rawValue: rawEvent) ?? .unknown
        }
    }

    var kind: Kind
    var rawEvent: String
    var sessionID: String?
    var toolName: String?
    /// Le fichier que Claude est en train de toucher, extrait de `tool_input`.
    var filePath: String?
    var cwd: String?
    var message: String?
    /// Horodaté à la réception : les événements servent à l'affichage en
    /// direct, et l'horloge du Mac est la seule qu'on maîtrise.
    var receivedAt: Date = Date()

    /// Vrai quand Claude attend une décision de l'utilisateur.
    var isAwaitingPermission: Bool {
        guard kind == .notification else { return false }
        let text = (message ?? "").lowercased()
        return text.contains("permission") || text.contains("approve")
            || text.contains("autoris")
    }

    /// Les outils qui touchent un fichier nomment leur cible différemment.
    private static let pathKeys = ["file_path", "path", "notebook_path", "filePath"]

    /// Analyse une ligne du journal. Une ligne illisible est ignorée : un
    /// journal tronqué par une déconnexion ne doit pas faire tomber l'app.
    static func parse(line: String, at date: Date = Date()) -> HookEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawEvent = object["hook_event_name"] as? String
        else { return nil }

        var event = HookEvent(kind: Kind(rawEvent: rawEvent), rawEvent: rawEvent)
        event.receivedAt = date
        event.sessionID = object["session_id"] as? String
        event.toolName = object["tool_name"] as? String
        event.cwd = object["cwd"] as? String
        event.message = object["message"] as? String

        if let input = object["tool_input"] as? [String: Any] {
            for key in pathKeys {
                if let path = input[key] as? String, !path.isEmpty {
                    event.filePath = path
                    break
                }
            }
        }
        return event
    }
}

// MARK: - Ce que l'app en retient

/// L'état de Claude Code sur un hôte, reconstruit à partir du flux (§10).
struct ClaudeActivity: Equatable {
    var isActive = false
    /// Le fichier en cours de modification, affiché en direct.
    var currentFile: String?
    var currentTool: String?
    var isAwaitingPermission = false
    var lastEventAt: Date?

    /// Le nom court du fichier, pour la barre d'état.
    var currentFileName: String? {
        currentFile.map { ($0 as NSString).lastPathComponent }
    }

    mutating func apply(_ event: HookEvent) {
        lastEventAt = event.receivedAt

        switch event.kind {
        case .sessionStart:
            isActive = true
            isAwaitingPermission = false

        case .sessionEnd:
            isActive = false
            currentFile = nil
            currentTool = nil
            isAwaitingPermission = false

        case .preToolUse:
            isActive = true
            currentTool = event.toolName
            if let path = event.filePath { currentFile = path }

        case .postToolUse:
            isActive = true
            currentTool = nil

        case .stop:
            isActive = true
            currentTool = nil
            isAwaitingPermission = false

        case .notification:
            isActive = true
            if event.isAwaitingPermission { isAwaitingPermission = true }

        case .unknown:
            break
        }
    }
}
