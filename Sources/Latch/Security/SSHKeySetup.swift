//
//  SSHKeySetup.swift
//  Latch
//
//  SPEC §11 : « Proposer un bouton "configurer une clé pour cet hôte" qui
//  exécute `ssh-keygen` puis `ssh-copy-id` dans un panneau visible. »
//
//  Visible est le mot important. `ssh-copy-id` demande le mot de passe du
//  compte distant : il doit le demander dans un vrai TTY, sous les yeux de
//  l'utilisateur. Latch ne le lit pas, ne le stocke pas, ne le voit pas passer.
//

import Foundation

enum SSHKeySetup {

    /// Le type de clé recommandé, et celui du §14.
    static let keyName = "id_ed25519"

    static var privateKeyPath: String { NSHomeDirectory() + "/.ssh/" + keyName }
    static var publicKeyPath: String { privateKeyPath + ".pub" }

    static func hasKey(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: privateKeyPath)
    }

    /// L'authentification par clé fonctionne-t-elle déjà sur cet hôte ?
    ///
    /// `BatchMode` interdit toute invite : si ssh a besoin d'un mot de passe,
    /// il échoue au lieu de le demander, et c'est exactement la réponse qu'on
    /// cherche.
    static func worksWithoutPassword(alias: String, timeout: Int = 6) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(timeout)",
            "-o", "StrictHostKeyChecking=accept-new",
            alias, "true",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// La commande jouée dans le panneau.
    ///
    /// Deux précautions valent d'être lues : la clé existante n'est **jamais**
    /// écrasée — `ssh-keygen` ne tourne que s'il n'y en a pas — et rien n'est
    /// forcé sans phrase de passe : c'est `ssh-keygen` lui-même qui la demande,
    /// interactivement, et l'utilisateur décide.
    static func setupCommand(alias: String, comment: String? = nil) -> String {
        let key = ShellQuoting.quoted(privateKeyPath)
        let publicKey = ShellQuoting.quoted(publicKeyPath)
        let host = ShellQuoting.quoted(alias)
        let label = ShellQuoting.quoted(comment ?? "\(NSUserName())@\(hostName()) (Latch)")

        return [
            // Une clé déjà là est une clé qu'on garde.
            "if [ -f \(key) ]; then echo 'latch: clé existante réutilisée : '\(key);",
            "else ssh-keygen -t ed25519 -C \(label) -f \(key); fi",
            "&& ssh-copy-id -i \(publicKey) \(host)",
        ].joined(separator: " ")
    }

    private static func hostName() -> String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }

    static let explanation =
        "ssh-copy-id demandera le mot de passe du compte distant. Il est saisi "
        + "dans le terminal, par toi : Latch ne le lit pas et ne le garde pas."
}
