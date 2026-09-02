//
//  ServerProbe.swift
//  Latch
//
//  La sonde du SPEC §6 : un seul aller-retour, au premier contact avec un hôte.
//  Le résultat est mis en cache sur le `Server` et expire au bout de 7 jours.
//

import Foundation

enum ServerProbe {

    /// Les emplacements que `command -v` rate dans un shell non interactif.
    /// `~/.local/bin` est celui de l'installeur officiel de Claude Code.
    static let fallbackDirectories = [
        "$HOME/.local/bin", "/usr/local/bin", "/opt/homebrew/bin", "/snap/bin",
    ]

    /// La commande du §6, augmentée d'un balayage des emplacements habituels.
    ///
    /// Le §6 s'arrête à `command -v`, et prévient que le support n°1 sera un
    /// outil qui marche en session mais que la sonde ne voit pas. Autant le
    /// détecter : un shell non interactif ne lit pas `~/.bashrc`, donc pas le
    /// `PATH` qu'on y a mis. Toujours un seul aller-retour.
    static var remoteScript: String {
        let directories = fallbackDirectories.map { "\"\($0)\"" }.joined(separator: " ")
        return [
            "command -v tmux mosh-server claude",
            "tmux -V 2>/dev/null",
            ". /etc/os-release 2>/dev/null && echo $ID",
            "for d in \(directories); do for t in tmux mosh-server claude; do "
                + "[ -x \"$d/$t\" ] && echo \"LATCH_OFFPATH $t $d/$t\"; done; done",
        ].joined(separator: "; ") + "; true"
    }

    enum ProbeError: LocalizedError {
        case unreachable(status: Int32, message: String)

        var errorDescription: String? {
            guard case .unreachable(let status, let message) = self else { return nil }
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "L'hôte n'a pas répondu (code \(status))."
                : detail
        }
    }

    // MARK: - Exécution

    /// Interroge l'hôte. `BatchMode` interdit toute demande interactive : une
    /// sonde ne doit jamais bloquer sur un prompt de mot de passe.
    static func probe(alias: String, timeout: Int = 8) async throws -> ProbeResult {
        let output = try await runSSH(alias: alias, timeout: timeout)
        return parse(output)
    }

    private static func runSSH(alias: String, timeout: Int) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(timeout)",
            "-o", "StrictHostKeyChecking=accept-new",
            alias,
            remoteScript,
        ]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProbeError.unreachable(
                status: process.terminationStatus,
                message: String(decoding: stderr, as: UTF8.self)
            )
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    // MARK: - Analyse

    /// Sépare les trois réponses mélangées dans la sortie :
    /// des chemins (`/usr/bin/tmux`), une version (`tmux 3.2a`), un identifiant
    /// de distribution (`ubuntu`).
    static func parse(_ output: String) -> ProbeResult {
        var result = ProbeResult()

        var found = Set<String>()
        var candidates: [String: String] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("LATCH_OFFPATH ") {
                let fields = line.split(separator: " ")
                if fields.count == 3 { candidates[String(fields[1])] = String(fields[2]) }
                continue
            }

            if line.hasPrefix("tmux ") {
                result.tmuxVersion = String(line.dropFirst("tmux ".count))
                continue
            }

            if line.hasPrefix("/") {
                let tool = (line as NSString).lastPathComponent
                switch tool {
                case "tmux": result.hasTmux = true
                case "mosh-server": result.hasMoshServer = true
                case "claude": result.hasClaude = true
                default: break
                }
                found.insert(tool)
                continue
            }

            // Ce qui reste sans barre oblique ni préfixe connu est
            // l'identifiant de `/etc/os-release`, éventuellement entre
            // guillemets — certaines distributions écrivent `ID="rocky"`.
            result.osID = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        // Trouvé sur le disque mais pas sur le PATH : l'outil est là, il est
        // simplement invisible d'ici. On le compte comme présent — le
        // proposer à l'installation serait faux — et on garde son chemin pour
        // pouvoir expliquer pourquoi la sonde a failli se tromper.
        for (tool, path) in candidates where !found.contains(tool) {
            result.offPathTools[tool] = path
            switch tool {
            case "tmux": result.hasTmux = true
            case "mosh-server": result.hasMoshServer = true
            case "claude": result.hasClaude = true
            default: break
            }
        }

        return result
    }
}
