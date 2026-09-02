//
//  ShellQuoting.swift
//  Latch
//
//  Le point le plus fragile du projet (SPEC §5). Tout ce qui échappe une chaîne
//  passe par ici, et rien d'autre ne bricole des guillemets à la main.
//
//  Trois couches se superposent dans une commande Latch :
//
//    1. le `/bin/sh -c` local qui exécute la chaîne complète ;
//    2. le shell de connexion distant, pour ssh (mosh, lui, exécute
//       directement, sans shell — d'où le besoin d'un `sh -c` explicite) ;
//    3. le `/bin/sh -c` que tmux ouvre pour sa commande de fenêtre.
//

import Foundation

enum ShellQuoting {

    /// Caractères qu'un shell POSIX laisse passer sans les interpréter.
    private static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:@%+,=")

    static func needsQuoting(_ value: String) -> Bool {
        value.isEmpty || value.contains { !safe.contains($0) }
    }

    /// Entoure de guillemets simples, seule protection totale d'un shell POSIX.
    /// Une apostrophe interne sort de la citation, s'échappe, et y rentre.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Ne cite que si c'est nécessaire, pour garder les commandes lisibles.
    static func quoted(_ value: String) -> String {
        needsQuoting(value) ? singleQuoted(value) : value
    }

    /// Échappe pour une insertion entre guillemets doubles. Le `$` est échappé
    /// aussi : on veut que `$SHELL` traverse le shell local intact et ne soit
    /// développé que de l'autre côté.
    static func escapedForDoubleQuotes(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count + 8)
        for character in value {
            if character == "\\" || character == "\"" || character == "`" || character == "$" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// Entoure de guillemets doubles en échappant l'intérieur.
    static func doubleQuoted(_ value: String) -> String {
        "\"" + escapedForDoubleQuotes(value) + "\""
    }

    // MARK: - Chemins distants

    /// Un chemin dont le tilde doit rester vivant jusqu'au shell distant.
    ///
    /// tmux n'étend pas le tilde : `tmux new -c "~/api"` atterrit dans le
    /// répertoire personnel, silencieusement. Le `~` doit donc arriver à tmux
    /// **déjà** étendu par un shell, ce qui impose de le laisser hors des
    /// guillemets et de ne citer que le reste du chemin.
    static func remotePath(_ path: String) -> String {
        guard path.hasPrefix("~") else { return quoted(path) }

        // Le préfixe tilde s'arrête à la **première barre oblique non citée**.
        // La barre doit donc rester dehors avec le tilde : `~'/mes projets'` ne
        // contient plus aucune barre nue, le shell ne reconnaît plus de préfixe
        // tilde et laisse la chaîne telle quelle. C'est `~/'mes projets'`.
        let afterSlash = path.firstIndex(of: "/").map(path.index(after:)) ?? path.endIndex
        let prefix = String(path[path.startIndex..<afterSlash])
        let rest = String(path[afterSlash...])

        // `~`, `~/`, `~billy/` sont sûrs tels quels ; un nom d'utilisateur
        // exotique ne l'est pas, et là on préfère tout citer et perdre
        // l'expansion plutôt que produire une commande imprévisible.
        let user = prefix.dropFirst().drop(while: { $0 == "/" })
        guard !needsQuoting(String(user)) || user.isEmpty else { return quoted(path) }

        if rest.isEmpty { return prefix }
        return needsQuoting(rest) ? prefix + singleQuoted(rest) : prefix + rest
    }

    /// Un chemin qui exige qu'un shell le développe : tilde ou variable.
    /// C'est ce qui décide si mosh, qui n'ouvre aucun shell distant, doit être
    /// enveloppé dans un `sh -c` (voir `CommandBuilder`).
    static func needsShellExpansion(_ path: String) -> Bool {
        path.hasPrefix("~") || path.contains("$") || path.contains("`")
    }
}
