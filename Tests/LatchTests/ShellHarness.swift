//
//  ShellHarness.swift
//  LatchTests
//
//  Outillage de test : exécute une commande avec un `/bin/sh` réel et rend la
//  liste d'arguments que le programme appelé a effectivement reçue.
//
//  C'est la seule façon honnête de tester l'échappement. Comparer des chaînes
//  écrites à la main ne prouve rien : si on se trompe dans le code, on se
//  trompe pareil dans le test.
//

import Foundation

enum ShellHarness {

    enum HarnessError: Error {
        case launchFailed(String)
    }

    /// Exécute `command` via `/bin/sh -c`, avec de faux `tmux`, `ssh`, `mosh`,
    /// `et` et `argv` en tête du `PATH`. Chacun se contente d'imprimer ses
    /// arguments : rien ne se connecte nulle part.
    ///
    /// - Returns: les arguments reçus par le premier de ces programmes appelé.
    static func arguments(of command: String) throws -> [String] {
        let directory = try stubDirectory()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        // Les commandes de Latch se terminent souvent par `exec $SHELL`, qui
        // garde la session tmux en vie. Ici, ça remplacerait le shell du
        // harnais par un shell interactif qui ne rendrait jamais la main : on
        // lui donne un `$SHELL` qui sort tout de suite.
        environment["SHELL"] = "/usr/bin/true"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Les arguments sont séparés par un octet nul : une chaîne de test
        // contient un retour à la ligne, un découpage par lignes mentirait.
        return data
            .split(separator: 0, omittingEmptySubsequences: false)
            .dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Faux binaires

    private static let stubNames = ["argv", "tmux", "ssh", "mosh", "et"]

    private static var cachedDirectory: URL?

    private static func stubDirectory() throws -> URL {
        if let cachedDirectory { return cachedDirectory }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-shell-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = """
            #!/bin/sh
            for argument in "$@"; do
                printf '%s\\000' "$argument"
            done
            """

        for name in stubNames {
            let url = directory.appendingPathComponent(name)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }

        cachedDirectory = directory
        return directory
    }
}
