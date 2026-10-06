//
//  Shortcut.swift
//  Latch
//
//  Le modèle de la SPEC §4. Persisté en JSON, sans le moindre secret.
//

import Foundation

// MARK: - Raccourci

struct Shortcut: Codable, Identifiable, Equatable {
    /// Ce que l'ancienne valeur par défaut valait : un nom pré-rempli qui se
    /// lit comme un libellé vide. On le traite comme tel plutôt que de
    /// l'afficher à la place du vrai nom de session.
    static let unnamed = "Nouvelle session"

    var id: UUID = UUID()
    /// Un libellé libre, facultatif. « API · Claude ».
    var name: String

    /// Le nom affiché partout : barre latérale, onglet, infobulle. Sans
    /// libellé, c'est la session tmux — c'est elle qu'on reconnaît, et
    /// afficher deux noms différents pour la même chose à deux endroits de
    /// l'écran est ce qui rendait l'onglet incompréhensible.
    var displayName: String {
        let label = name.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label != Shortcut.unnamed else {
            return connection.tmuxSession
        }
        return label
    }
    /// Commandes locales, l'ordre compte.
    var preflight: [Preflight] = []
    /// Exactement une, non supprimable.
    var connection: Connection
    /// Fenêtres tmux, l'ordre compte.
    var windows: [TmuxWindow] = []
    /// Si non nil, remplace tout le reste — y compris le pré-vol.
    var customCommand: String?

    /// Le mode « personnalisé » du §9.2 : l'aperçu a été édité à la main.
    var isCustom: Bool { customCommand != nil }
}

// MARK: - Pré-vol

struct Preflight: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    /// Exécutée localement via `/bin/sh -c`.
    var command: String
    /// Sinon : avertir et continuer.
    var failureIsFatal: Bool = true
}

// MARK: - Connexion

struct Connection: Codable, Equatable {
    var transport: Transport = .mosh
    /// La destination ssh : un alias de `~/.ssh/config`, ou directement
    /// `utilisateur@adresse`. Le fichier de configuration n'est **pas**
    /// obligatoire — ssh essaie de lui-même les clés par défaut du Mac.
    var host: String
    /// Port ssh, quand ce n'est pas 22. `nil` laisse ssh décider, donc le
    /// fichier de configuration s'il en dit quelque chose.
    var port: Int?
    /// Clé privée à utiliser, quand les clés par défaut ne conviennent pas.
    var identityFile: String?
    /// `-J`, seulement si `transport == .sshJump`.
    var jumpHost: String?
    /// « api »
    var tmuxSession: String
    /// « ~/api » — étendu par le shell distant, jamais par tmux (voir §5).
    var workingDirectory: String?
    var initialCommand: InitialCommand = .shell
    /// « --model opus --permission-mode acceptEdits »
    var extraArgs: String?
    /// Ajoute `; exec $SHELL`.
    var keepShellOnExit: Bool = true
    /// `tmux -CC`. Incompatible mosh, refusé au niveau du modèle.
    var controlMode: Bool = false
}

enum Transport: String, Codable, CaseIterable, Identifiable {
    case mosh, ssh, sshJump, eternalTerminal, local

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mosh: return localized("mosh")
        case .ssh: return localized("ssh")
        case .sshJump: return localized("ssh via rebond")
        case .eternalTerminal: return localized("Eternal Terminal")
        case .local: return localized("local")
        }
    }

    /// Un transport qui n'ouvre pas de connexion n'a pas d'hôte.
    var isRemote: Bool { self != .local }
}

enum InitialCommand: Codable, Equatable, Hashable {
    case shell
    case claude
    case claudeContinue
    case claudeResume
    case custom(String)

    var label: String {
        switch self {
        case .shell: return localized("shell seul")
        case .claude: return "claude"
        case .claudeContinue: return "claude --continue"
        case .claudeResume: return "claude --resume"
        case .custom: return localized("commande personnalisée…")
        }
    }

    /// La commande lancée à la création de la session, sans les arguments
    /// supplémentaires. `nil` pour un shell nu : tmux ouvre déjà un shell.
    var executable: String? {
        switch self {
        case .shell: return nil
        case .claude: return "claude"
        case .claudeContinue: return "claude --continue"
        case .claudeResume: return "claude --resume"
        case .custom(let command):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Fenêtre tmux

struct TmuxWindow: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// « logs »
    var name: String
    /// « journalctl -fu api »
    var command: String
}
