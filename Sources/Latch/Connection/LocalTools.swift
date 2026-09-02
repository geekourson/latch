//
//  LocalTools.swift
//  Latch
//
//  Le Mac est un hôte comme un autre.
//
//  Le §6 ne sonde que les serveurs, mais un raccourci `local` a exactement les
//  mêmes besoins — et le même piège, en pire : `launchctl getenv PATH` est vide
//  sur un Mac ordinaire, donc une app lancée depuis le Finder n'hérite que de
//  `/usr/bin:/bin:/usr/sbin:/sbin`. Homebrew n'y est pas. Un `tmux` installé
//  reste introuvable, et la session échoue sur « command not found » sans
//  expliquer pourquoi.
//
//  On cherche donc par chemin absolu, comme pour `mosh-client`, et l'absence
//  fait basculer la cascade du §6 au lieu de faire échouer la connexion.
//

import Foundation

enum LocalTools {

    /// Les emplacements habituels, dans l'ordre où on les préfère. Le `PATH`
    /// n'est pas consulté : celui d'une app lancée depuis le Finder ne
    /// contient rien d'utile.
    static let searchPaths = [
        "/opt/homebrew/bin",   // Homebrew sur Apple Silicon
        "/usr/local/bin",      // Homebrew sur Intel, MacPorts
        "/opt/local/bin",      // MacPorts
        "/usr/bin",
        "/bin",
    ]

    /// Ce que launchd donne à une app sans réglage particulier.
    static let launchdPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func path(of tool: String, fileManager: FileManager = .default) -> String? {
        for directory in searchPaths {
            let candidate = directory + "/" + tool
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Vrai quand l'outil existe mais hors de ce qu'une app voit par défaut :
    /// il faudra l'appeler par son chemin absolu.
    static func isOffPath(_ tool: String, fileManager: FileManager = .default) -> Bool {
        guard let found = path(of: tool, fileManager: fileManager) else { return false }
        return !launchdPaths.contains((found as NSString).deletingLastPathComponent)
    }

    /// La sonde du §6, appliquée au Mac. Pas de `mosh-server` ici : rien ne se
    /// connecte, et `claude` local n'entre pas dans la cascade.
    static func probe(fileManager: FileManager = .default) -> ProbeResult {
        var result = ProbeResult()
        result.osID = "macos"
        // Une session locale n'a pas de connexion à dégrader : mosh n'a aucun
        // sens ici, et l'annoncer manquant afficherait un bandeau pour rien.
        result.hasMoshServer = true

        if let tmux = path(of: "tmux", fileManager: fileManager) {
            result.hasTmux = true
            result.tmuxVersion = version(of: tmux)
            if isOffPath("tmux", fileManager: fileManager) {
                result.offPathTools["tmux"] = tmux
            }
        }
        return result
    }

    private static func version(of tmuxPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-V"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("tmux ") ? String(text.dropFirst("tmux ".count)) : nil
    }

    /// Homebrew, qui installe tout le reste sur un Mac.
    static var homebrewPath: String? { path(of: "brew") }

    static let missingHomebrewMessage =
        "Homebrew n'est pas installé sur ce Mac : la commande ci-dessus n'aura "
        + "rien pour s'exécuter. Son propre installeur est sur brew.sh."

    static let homebrewURL = URL(string: "https://brew.sh")!

    static let missingTmuxMessage =
        "tmux n'est pas installé sur ce Mac : la session locale n'est qu'un "
        + "shell, et ne survivra pas à la fermeture de l'onglet. "
        + "« brew install tmux » y remédie."
}
