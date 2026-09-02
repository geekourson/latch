//
//  HookEvent.swift
//  Latch
//
//  SPEC §10. Claude Code tourne **sur le serveur**, pas sur le Mac : tout ce
//  que Latch en sait passe par les hooks, écrits ligne par ligne dans un
//  fichier que l'app suit par une connexion ssh secondaire.
//

import Foundation

/// Ce que Claude attend de toi.
///
/// La distinction compte : une autorisation bloque le travail sur-le-champ, une
/// réponse attend simplement que tu reviennes. Les confondre, c'est soit crier
/// pour rien, soit rater le seul moment où il fallait regarder.
enum ClaudeAttention: Equatable {
    /// « Claude needs your permission » : un outil est suspendu.
    case permission
    /// Le tour est fini, ou Claude a posé une question et attend.
    case reply

    /// L'autorisation prime : elle bloque, l'autre non.
    static func stronger(_ lhs: ClaudeAttention?, _ rhs: ClaudeAttention?) -> ClaudeAttention? {
        if lhs == .permission || rhs == .permission { return .permission }
        return lhs ?? rhs
    }
}

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
    /// `permission_prompt`, `idle_prompt`… Claude Code le renseigne ; les
    /// versions plus anciennes ne le faisaient pas, d'où le repli sur le texte.
    var notificationType: String?
    /// Horodaté à la réception : les événements servent à l'affichage en
    /// direct, et l'horloge du Mac est la seule qu'on maîtrise.
    var receivedAt: Date = Date()

    /// Ce que Claude attend, quand il attend quelque chose.
    var attention: ClaudeAttention? {
        // Un tour qui se termine rend la main : c'est le signal le plus
        // immédiat, et le seul qui arrive sans délai.
        if kind == .stop { return .reply }
        guard kind == .notification else { return nil }

        switch notificationType {
        case "permission_prompt": return .permission
        case "idle_prompt": return .reply
        default: break
        }

        // Sans `notification_type`, le texte est tout ce qu'on a.
        let text = (message ?? "").lowercased()
        if text.contains("permission") || text.contains("approve")
            || text.contains("autoris") { return .permission }
        if text.contains("waiting for your input") || text.contains("attend") { return .reply }
        return nil
    }

    /// Vrai quand Claude est bloqué sur une autorisation.
    var isAwaitingPermission: Bool { attention == .permission }

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
        event.notificationType = object["notification_type"] as? String

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
    /// Ce que Claude attend, ou rien s'il travaille.
    var attention: ClaudeAttention?
    /// Le répertoire de la session Claude, seul lien avec une session tmux :
    /// les hooks ne savent rien de tmux.
    var directory: String?
    var lastEventAt: Date?

    var isAwaitingPermission: Bool { attention == .permission }
    var needsAttention: Bool { attention != nil }

    /// Le nom court du fichier, pour la barre d'état.
    var currentFileName: String? {
        currentFile.map { ($0 as NSString).lastPathComponent }
    }

    mutating func apply(_ event: HookEvent) {
        lastEventAt = event.receivedAt
        if let cwd = event.cwd { directory = cwd }

        switch event.kind {
        case .sessionStart:
            isActive = true
            attention = nil

        case .sessionEnd:
            isActive = false
            currentFile = nil
            currentTool = nil
            attention = nil

        // Un outil qui démarre ou se termine, c'est Claude qui travaille :
        // ce qu'il attendait ne l'attend plus.
        case .preToolUse:
            isActive = true
            currentTool = event.toolName
            attention = nil
            if let path = event.filePath { currentFile = path }

        case .postToolUse:
            isActive = true
            currentTool = nil
            attention = nil

        case .stop:
            isActive = true
            currentTool = nil
            attention = event.attention

        case .notification:
            isActive = true
            attention = ClaudeAttention.stronger(event.attention, attention)

        case .unknown:
            break
        }
    }
}
