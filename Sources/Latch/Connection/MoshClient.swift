//
//  MoshClient.swift
//  Latch
//
//  Où trouver mosh (SPEC §7).
//
//  L'objectif du §7 est de ne pas exiger Homebrew de l'utilisateur : les
//  binaires publiés embarquent `mosh-client` dans
//  `Latch.app/Contents/MacOS/mosh-client`, invoqué par **chemin absolu**,
//  jamais via le `PATH`. Tant qu'il n'est pas là — c'est le cas d'une
//  compilation locale — Latch retombe sur le `mosh` du système et le dit.
//

import Foundation

enum MoshClient {

    /// Ce que Latch a trouvé pour parler mosh.
    enum Availability: Equatable {
        /// `mosh-client` embarqué dans le bundle : le cas nominal du §7.
        case bundled(path: String)
        /// Le script `mosh` du système, avec ses propres dépendances.
        case system(path: String)
        /// Rien. Le transport mosh n'est pas ouvrable sur ce Mac.
        case absent

        var isAvailable: Bool { self != .absent }
    }

    /// Emplacements habituels du `mosh` du système. On ne consulte pas le
    /// `PATH` : une app lancée depuis le Finder hérite de celui de launchd,
    /// qui ne contient ni `/opt/homebrew/bin` ni `/usr/local/bin`.
    static let systemSearchPaths = [
        "/opt/homebrew/bin/mosh",   // Homebrew sur Apple Silicon
        "/usr/local/bin/mosh",      // Homebrew sur Intel, MacPorts
        "/opt/local/bin/mosh",      // MacPorts
        "/usr/bin/mosh",
    ]

    static var bundledPath: String? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent()
        else { return nil }
        return directory.appendingPathComponent("mosh-client").path
    }

    static func locate(fileManager: FileManager = .default) -> Availability {
        if let bundled = bundledPath, fileManager.isExecutableFile(atPath: bundled) {
            return .bundled(path: bundled)
        }
        for candidate in systemSearchPaths where fileManager.isExecutableFile(atPath: candidate) {
            return .system(path: candidate)
        }
        return .absent
    }

    /// Ce que l'interface dit quand mosh manque des deux côtés.
    static var missingLocallyMessage: String { localized(
            "mosh n'est pas installé sur ce Mac. Les binaires publiés de Latch "
            + "embarquent mosh-client ; pour une compilation locale, installe-le "
            + "avec « brew install mosh », ou choisis le transport ssh."
    ) }
}
