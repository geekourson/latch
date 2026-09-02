//
//  TolerantDecoding.swift
//  Latch
//
//  Un fichier de configuration doit survivre aux versions de l'app.
//
//  Swift ne retombe **pas** sur la valeur par défaut d'une propriété quand la
//  clé est absente du JSON : le décodeur synthétisé lève une erreur. Ajouter un
//  champ au modèle rend donc illisibles tous les fichiers écrits avant — c'est
//  arrivé une fois, en ajoutant `offPathTools` à `ProbeResult`, et l'app a
//  démarré sur une barre latérale vide.
//
//  Chaque type persisté décode donc lui-même, clé par clé, en tolérant les
//  absences. Seul ce qui n'a pas de valeur de repli sensée reste obligatoire.
//

import Foundation

/// Une liste dont les éléments illisibles sont écartés un par un, au lieu
/// d'emporter tous les autres. Un raccourci cassé ne doit pas faire disparaître
/// la barre latérale — mais leur nombre remonte, l'éviction n'est pas muette.
struct Lenient<Element: Decodable>: Decodable {
    var values: [Element] = []
    var skipped = 0

    /// Décode n'importe quoi sans rien en garder : sert à faire avancer le
    /// conteneur après un élément refusé, qui sinon bloquerait la boucle.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init() {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let index = container.currentIndex
            if let value = try? container.decode(Element.self) {
                values.append(value)
                continue
            }
            skipped += 1
            if container.currentIndex == index {
                _ = try? container.decode(Skipped.self)
            }
            // Si rien n'avance, on s'arrête plutôt que de tourner sans fin.
            if container.currentIndex == index { break }
        }
    }
}

extension KeyedDecodingContainer {

    /// La valeur, ou le repli si la clé manque ou n'est pas du bon type.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded ?? fallback
    }

    /// Une valeur facultative, tolérante à un contenu inattendu.
    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Une liste dont les éléments illisibles sont écartés un par un.
    func lenient<Element: Decodable>(_ key: Key, of type: Element.Type) -> Lenient<Element> {
        guard let decoded = try? decodeIfPresent(Lenient<Element>.self, forKey: key) else {
            return Lenient<Element>()
        }
        return decoded ?? Lenient<Element>()
    }
}

// MARK: - Raccourcis

extension Shortcut {
    enum CodingKeys: String, CodingKey {
        case id, name, preflight, connection, windows, customCommand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Un raccourci sans connexion n'est pas un raccourci : celle-là reste
        // obligatoire, et son absence doit se voir.
        connection = try container.decode(Connection.self, forKey: .connection)
        id = container.value(.id, or: UUID())
        name = container.value(.name, or: "Sans nom")
        preflight = container.value(.preflight, or: [])
        windows = container.value(.windows, or: [])
        customCommand = container.optional(.customCommand)
    }
}

extension Preflight {
    enum CodingKeys: String, CodingKey { case id, label, command, failureIsFatal }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, or: UUID())
        label = container.value(.label, or: "Étape")
        command = container.value(.command, or: "")
        failureIsFatal = container.value(.failureIsFatal, or: true)
    }
}

extension Connection {
    enum CodingKeys: String, CodingKey {
        case transport, host, port, identityFile, jumpHost, tmuxSession
        case workingDirectory, initialCommand, extraArgs, keepShellOnExit, controlMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = container.value(.transport, or: .mosh)
        host = container.value(.host, or: "")
        port = container.optional(.port)
        identityFile = container.optional(.identityFile)
        jumpHost = container.optional(.jumpHost)
        tmuxSession = container.value(.tmuxSession, or: "session")
        workingDirectory = container.optional(.workingDirectory)
        initialCommand = container.value(.initialCommand, or: .shell)
        extraArgs = container.optional(.extraArgs)
        keepShellOnExit = container.value(.keepShellOnExit, or: true)
        controlMode = container.value(.controlMode, or: false)
    }
}

extension TmuxWindow {
    enum CodingKeys: String, CodingKey { case id, name, command }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, or: UUID())
        name = container.value(.name, or: "fenêtre")
        command = container.value(.command, or: "")
    }
}

// MARK: - Serveurs

extension Server {
    enum CodingKeys: String, CodingKey {
        case id, name, sshAlias, probe, probedAt, skipUpgradePrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Sans alias, on ne saurait pas où se connecter.
        sshAlias = try container.decode(String.self, forKey: .sshAlias)
        id = container.value(.id, or: UUID())
        name = container.value(.name, or: sshAlias)
        probe = container.optional(.probe)
        probedAt = container.optional(.probedAt)
        skipUpgradePrompt = container.value(.skipUpgradePrompt, or: false)
    }
}

extension ProbeResult {
    enum CodingKeys: String, CodingKey {
        case hasTmux, tmuxVersion, hasMoshServer, hasClaude, osID, offPathTools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasTmux = container.value(.hasTmux, or: false)
        tmuxVersion = container.optional(.tmuxVersion)
        hasMoshServer = container.value(.hasMoshServer, or: false)
        hasClaude = container.value(.hasClaude, or: false)
        osID = container.optional(.osID)
        offPathTools = container.value(.offPathTools, or: [:])
    }
}

// MARK: - Réglages et thèmes

extension Preferences {
    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, lineSpacing, padding, themeID, language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontName = container.optional(.fontName)
        fontSize = container.value(.fontSize, or: 13)
        lineSpacing = container.value(.lineSpacing, or: 1.25)
        padding = container.value(.padding, or: 20)
        themeID = container.optional(.themeID)
        language = container.value(.language, or: .system)
    }
}

extension Theme {
    enum CodingKeys: String, CodingKey {
        case id, name, source, background, foreground, cursor
        case selectionBackground, selectionForeground, ansi
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Un thème sans ses seize couleurs n'habille rien.
        ansi = try container.decode([ThemeColor].self, forKey: .ansi)
        id = container.value(.id, or: UUID())
        name = container.value(.name, or: "Sans nom")
        source = container.value(.source, or: .builtIn)
        background = container.value(.background, or: ThemeColor(0x000000))
        foreground = container.value(.foreground, or: ThemeColor(0xFFFFFF))
        cursor = container.value(.cursor, or: foreground)
        selectionBackground = container.value(.selectionBackground, or: ThemeColor(0x303030))
        selectionForeground = container.optional(.selectionForeground)
    }
}
