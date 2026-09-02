//
//  SSHConfig.swift
//  Latch
//
//  Le §4 dit « alias ~/.ssh/config de préférence ». Autant les proposer : au
//  premier lancement, la barre latérale se remplit toute seule avec les hôtes
//  que l'utilisateur a déjà configurés.
//
//  Lecture seule. Latch n'écrit jamais dans ce fichier.
//

import Foundation

enum SSHConfig {

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }

    /// Les alias déclarés par des lignes `Host`, dans l'ordre du fichier.
    ///
    /// Les motifs (`*`, `?`, `!`) sont écartés : `Host *` n'est pas un serveur,
    /// c'est un bloc de réglages par défaut.
    static func hosts(in contents: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // `Host billy autre` déclare deux alias sur une ligne. Le mot-clé
            // est insensible à la casse, et un `=` peut remplacer l'espace.
            let normalised = line.replacingOccurrences(of: "=", with: " ")
            let fields = normalised.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = fields.first, keyword.lowercased() == "host" else { continue }

            for alias in fields.dropFirst() {
                guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!") else { continue }
                if seen.insert(alias).inserted { found.append(alias) }
            }
        }
        return found
    }

    static func hosts(at url: URL = defaultURL) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return hosts(in: contents)
    }
}
