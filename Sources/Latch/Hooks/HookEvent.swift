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
        case userPromptSubmit = "UserPromptSubmit"
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
    /// Le panneau tmux où tourne Claude (`%12`), ajouté par le hook à partir
    /// de `$TMUX_PANE`. C'est ce qui rattache l'événement à **une** fenêtre ;
    /// absent hors de tmux, ou avec un hook installé par une version
    /// antérieure.
    var pane: String?
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
        // Une question posée par l'outil dédié n'est ni une fin de tour ni une
        // autorisation : sans ça, elle ne se voyait qu'à la notification
        // d'inactivité, une minute plus tard.
        if kind == .preToolUse, toolName == Self.questionTool { return .reply }
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

    static let questionTool = "AskUserQuestion"

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
        if let pane = object["latch_pane"] as? String, !pane.isEmpty { event.pane = pane }
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
    /// Le répertoire de la session Claude. Seul lien avec tmux quand le hook
    /// ne fournit pas de panneau.
    var directory: String?
    /// Le panneau tmux de cette session Claude, quand le hook le connaît.
    var pane: String?
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
        if let pane = event.pane { self.pane = pane }

        switch event.kind {
        case .sessionStart:
            isActive = true
            attention = nil

        case .sessionEnd:
            isActive = false
            currentFile = nil
            currentTool = nil
            attention = nil

        // Un message envoyé, c'est Claude qui se remet au travail.
        case .userPromptSubmit:
            isActive = true
            currentTool = nil
            attention = nil

        // Un outil qui démarre ou se termine, c'est Claude qui travaille :
        // ce qu'il attendait ne l'attend plus — sauf si l'outil est une
        // question.
        case .preToolUse:
            isActive = true
            currentTool = event.toolName
            attention = event.attention
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

// MARK: - Plusieurs Claude sur un hôte

/// Toutes les sessions Claude d'un hôte, et ce qui les relie aux fenêtres tmux.
///
/// Un hôte peut faire tourner plusieurs Claude à la fois : un seul état par
/// hôte laissait le dernier événement reçu parler pour tous. Chaque session
/// Claude garde donc le sien, et c'est son panneau tmux qui la place dans une
/// fenêtre.
struct ClaudeRoster: Equatable {
    /// Par identifiant de session Claude.
    var activities: [String: ClaudeActivity] = [:]

    mutating func apply(_ event: HookEvent) {
        let key = event.sessionID ?? ""
        // Une session terminée n'a plus rien à montrer : on l'oublie, sinon
        // elle s'accumule.
        if event.kind == .sessionEnd {
            activities[key] = nil
            return
        }
        activities[key, default: ClaudeActivity()].apply(event)
    }

    /// Les sessions encore là. Quand on connaît les panneaux de l'hôte, une
    /// session dont le panneau a disparu est périmée : Claude a été tué sans
    /// pouvoir envoyer `SessionEnd`.
    func live(panes: [String: String]?) -> [ClaudeActivity] {
        activities.values.filter { activity in
            guard activity.isActive else { return false }
            guard let pane = activity.pane, let panes else { return true }
            return panes[pane] != nil
        }
    }

    /// Le témoin d'une fenêtre : `panes` associe un panneau à l'identifiant
    /// de sa fenêtre (`session:index`).
    func activity(inWindow window: String, panes: [String: String]?) -> ClaudeActivity? {
        guard let panes else { return nil }
        return ClaudeActivity.mostPressing(
            live(panes: panes).filter { $0.pane.flatMap { panes[$0] } == window }
        )
    }

    /// Le témoin d'une session tmux : ses fenêtres, plus — pour un hook qui ne
    /// donne pas son panneau — ce que le répertoire permet de rattacher.
    func activity(
        inSession session: String, panes: [String: String]?, directory: String?
    ) -> ClaudeActivity? {
        let prefix = session + ":"
        return ClaudeActivity.mostPressing(live(panes: panes).filter { activity in
            if let pane = activity.pane {
                return panes?[pane]?.hasPrefix(prefix) == true
            }
            return directory != nil && activity.directory == directory
        })
    }
}

extension ClaudeActivity {
    /// Celle qui réclame le plus : une autorisation, puis une réponse, puis
    /// la plus récente. Un témoin qui en résume plusieurs ne doit pas cacher
    /// celle qui bloque.
    static func mostPressing(_ activities: [ClaudeActivity]) -> ClaudeActivity? {
        func rank(_ activity: ClaudeActivity) -> Int {
            switch activity.attention {
            case .permission: return 2
            case .reply: return 1
            case .none: return 0
            }
        }
        return activities.max { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return (lhs.lastEventAt ?? .distantPast) < (rhs.lastEventAt ?? .distantPast)
        }
    }
}
