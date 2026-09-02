//
//  HookInstaller.swift
//  Latch
//
//  Le script d'installation des hooks du §10, « exécuté depuis l'app avec
//  confirmation explicite de l'utilisateur ».
//
//  Deux principes, repris du §6 : rien n'est installé en silence, et ce qui
//  sera exécuté est montré en clair avant de l'être. La commande encode le
//  script en base64 pour traverser ssh sans se battre avec trois niveaux de
//  guillemets — mais l'interface affiche le script décodé, pas le blob.
//

import Foundation

enum HookInstaller {

    /// Où le serveur range ce qui appartient à Latch.
    static let remoteDirectory = "$HOME/.latch"
    static let remoteLogPath = "$HOME/.latch/events.jsonl"
    static let remoteHookPath = "$HOME/.latch/hook.sh"

    /// Les événements écoutés. Les quatre du §10, plus `Stop` et
    /// `Notification` — sans eux, « prévenir quand une tâche se termine ou
    /// qu'une permission est attendue » n'est pas réalisable.
    static let events = [
        "SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "Stop", "Notification",
    ]

    // MARK: - Le hook lui-même

    /// Écrit l'événement sur **une** ligne et rend la main tout de suite : un
    /// hook lent ralentit Claude Code à chaque outil utilisé.
    static let hookScript = """
        #!/bin/sh
        # Installé par Latch. Écrit chaque événement Claude Code sur une ligne,
        # que l'app suit par une connexion ssh secondaire.
        # Supprimer ce fichier et l'entrée correspondante dans
        # ~/.claude/settings.json suffit à tout désinstaller.
        set -u
        dir="$HOME/.latch"
        log="$dir/events.jsonl"
        mkdir -p "$dir" 2>/dev/null || exit 0

        # Le contenu JSON n'a pas de retour à la ligne nu : l'aplatir est sûr.
        { tr -d '\\n'; printf '\\n'; } >> "$log" 2>/dev/null

        # Le journal sert à l'affichage en direct, pas à l'archivage : on le
        # borne, sinon il grossit indéfiniment sur un serveur qui tourne.
        size=$(wc -c < "$log" 2>/dev/null || echo 0)
        if [ "$size" -gt 262144 ]; then
            tail -c 131072 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"
        fi

        # Toujours sortir proprement : un hook en échec interrompt Claude Code.
        exit 0
        """

    /// Fusionne les entrées dans `~/.claude/settings.json` **sans écraser** ce
    /// qui s'y trouve déjà : un utilisateur de Claude Code a souvent d'autres
    /// hooks, et les perdre serait impardonnable.
    static var settingsMergeScript: String {
        let eventList = events.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
            import json, os, sys

            path = os.path.expanduser("~/.claude/settings.json")
            os.makedirs(os.path.dirname(path), exist_ok=True)

            try:
                with open(path) as handle:
                    settings = json.load(handle)
            except FileNotFoundError:
                settings = {}
            except ValueError:
                sys.exit("latch: ~/.claude/settings.json est illisible, rien n'a ete touche")

            entry = {"type": "command", "command": os.path.expanduser("~/.latch/hook.sh"),
                     "timeout": 5}
            hooks = settings.setdefault("hooks", {})
            added = 0

            for event in [\(eventList)]:
                matchers = hooks.setdefault(event, [])
                # Deja installe ? On ne duplique pas.
                if any(entry["command"] == h.get("command")
                       for m in matchers for h in m.get("hooks", [])):
                    continue
                matchers.append({"matcher": "", "hooks": [dict(entry)]})
                added += 1

            if added:
                backup = path + ".latch-backup"
                if os.path.exists(path):
                    with open(path) as src, open(backup, "w") as dst:
                        dst.write(src.read())
                with open(path, "w") as handle:
                    json.dump(settings, handle, indent=2)
                    handle.write("\\n")

            print("latch: %d hook(s) ajoute(s)" % added)
            """
    }

    // MARK: - La commande

    /// La ligne à exécuter sur le serveur. `python3` est requis pour fusionner
    /// le JSON : bricoler ça en shell finirait par manger la configuration
    /// existante d'un utilisateur.
    static var installCommand: String {
        let hook = Data(hookScript.utf8).base64EncodedString()
        let merge = Data(settingsMergeScript.utf8).base64EncodedString()

        return [
            "command -v python3 >/dev/null || "
                + "{ echo 'latch: python3 est requis pour modifier ~/.claude/settings.json' >&2; exit 1; }",
            "mkdir -p ~/.latch",
            "printf %s '\(hook)' | base64 -d > ~/.latch/hook.sh",
            "chmod 755 ~/.latch/hook.sh",
            "printf %s '\(merge)' | base64 -d | python3 -",
        ].joined(separator: " && ")
    }

    /// La commande qui suit le journal, lancée sur une connexion ssh
    /// secondaire. `-n0` ignore l'historique — on veut le direct, pas un
    /// rejeu — et `-F` survit à la rotation du fichier.
    static var followCommand: String {
        "mkdir -p ~/.latch && touch ~/.latch/events.jsonl && "
            + "tail -n0 -F ~/.latch/events.jsonl"
    }

    // MARK: - Exécution depuis l'app

    /// Le §10 veut le script « exécuté depuis l'app avec confirmation
    /// explicite de l'utilisateur ». C'est possible sans rien demander de plus
    /// que la clé ssh : contrairement aux paquets du §6, l'installation des
    /// hooks n'écrit que dans le dossier personnel — `~/.latch/` et
    /// `~/.claude/settings.json`. Aucun `sudo`, donc aucun mot de passe.
    enum InstallError: LocalizedError {
        case failed(status: Int32, output: String)

        var errorDescription: String? {
            guard case .failed(let status, let output) = self else { return nil }
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "L'installation a échoué (code \(status))."
                : detail
        }
    }

    @discardableResult
    static func install(on alias: String) async throws -> String {
        try await run(installCommand, on: alias)
    }

    /// Les hooks sont-ils déjà en place ? Un aller-retour, sans rien modifier.
    static func isInstalled(on alias: String) async -> Bool {
        let check = "test -x ~/.latch/hook.sh && grep -q '.latch/hook.sh' ~/.claude/settings.json"
        return (try? await run(check, on: alias)) != nil
    }

    private static func run(_ command: String, on alias: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias, command]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw InstallError.failed(status: process.terminationStatus, output: text)
        }
        return text
    }

    static let uninstallHint =
        "Pour désinstaller : supprime ~/.latch/hook.sh et les entrées "
        + "correspondantes dans ~/.claude/settings.json. Latch en garde une "
        + "copie dans ~/.claude/settings.json.latch-backup."
}
