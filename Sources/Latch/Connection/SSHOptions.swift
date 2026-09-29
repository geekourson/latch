//
//  SSHOptions.swift
//  Latch
//
//  Ce qu'il faut ajouter à un `ssh` pour joindre un hôte donné.
//
//  Le §4 dit « alias ~/.ssh/config **de préférence** » : ce fichier n'est pas
//  obligatoire. `alex@192.168.1.10` suffit, et ssh essaie tout seul les clés
//  par défaut du Mac. Ces options ne servent qu'aux cas où les valeurs par
//  défaut ne conviennent pas — un port déplacé, une clé qui n'a pas un nom
//  standard.
//
//  Elles valent pour **toutes** les connexions vers cet hôte : la session, la
//  sonde du §6, le flux de hooks du §10, les fenêtres tmux. Une seule
//  définition, partout.
//

import Foundation

struct SSHOptions: Equatable {
    var port: Int?
    var identityFile: String?

    static let none = SSHOptions()

    var isEmpty: Bool { port == nil && identityFile == nil }

    init(port: Int? = nil, identityFile: String? = nil) {
        self.port = port.flatMap { (1...65535).contains($0) ? $0 : nil }
        let trimmed = identityFile?.trimmingCharacters(in: .whitespaces)
        self.identityFile = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    init(_ connection: Connection) {
        self.init(port: connection.port, identityFile: connection.identityFile)
    }

    /// Les arguments à insérer avant la destination.
    var arguments: [String] {
        var result: [String] = []
        if let port { result += ["-p", String(port)] }
        if let identityFile {
            result += ["-i", (identityFile as NSString).expandingTildeInPath]
            // Sans ça, ssh proposerait quand même les clés de l'agent et celles
            // par défaut, ce qui n'est pas ce qu'on demande en nommant une clé.
            result += ["-o", "IdentitiesOnly=yes"]
        }
        return result
    }

    /// La même chose, prête à s'insérer dans une ligne de commande.
    var commandLineFragment: String {
        arguments.map(ShellQuoting.quoted).joined(separator: " ")
    }

    /// mosh ne prend pas ces options directement : il les passe au ssh qu'il
    /// ouvre pour démarrer `mosh-server`, via `--ssh`.
    var moshArgument: String? {
        guard !isEmpty else { return nil }
        return "--ssh=" + (["ssh"] + arguments).joined(separator: " ")
    }
}
