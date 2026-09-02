//
//  MoshDriver.swift
//  Latch
//
//  SPEC §7. Deux chemins, selon ce que le Mac a sous la main :
//
//    — `mosh-client` embarqué dans le bundle, le cas nominal des binaires
//      publiés. Il faut alors refaire ce que fait le script `mosh` : ouvrir un
//      ssh vers `mosh-server new`, lire la ligne `MOSH CONNECT`, puis lancer le
//      client avec la clé **dans l'environnement** ;
//    — le `mosh` du système, qui sait déjà tout faire. C'est le repli d'une
//      compilation locale.
//
//  Deux contraintes dictent la forme du résultat :
//
//    — la clé de session ne doit jamais toucher la ligne de commande, où
//      n'importe quel `ps` de la machine la lirait. Le préfixe d'affectation
//      `MOSH_KEY=… exec …` la garde dans l'environnement du shell, qui se
//      remplace ensuite par le client ;
//    — `mosh-client` veut une adresse **numérique**. On résout donc l'alias
//      nous-mêmes, et `ssh -G` s'en charge parce qu'il applique tout le
//      `~/.ssh/config` : `HostName`, `Match`, les inclusions.
//

import Darwin
import Foundation

struct MoshDriver: ConnectionDriver {

    static let transport: Transport = .mosh

    enum MoshError: LocalizedError, Equatable {
        case notInstalled
        case unresolvableHost(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return MoshClient.missingLocallyMessage
            case .unresolvableHost(let host):
                return "Impossible de résoudre l'adresse de « \(host) ». "
                    + "mosh a besoin d'une adresse numérique, contrairement à ssh."
            }
        }
    }

    /// Locale imposée au serveur : mosh refuse de démarrer sans locale UTF-8, et
    /// celle de l'hôte n'a aucune raison d'en être une.
    static let remoteLocale = "en_US.UTF-8"

    var availability: MoshClient.Availability = MoshClient.locate()

    func plan(for shortcut: Shortcut, degradation: Degradation) async throws -> LaunchPlan {
        switch availability {
        case .system(let path):
            // Le script d'enrobage fait la poignée de main tout seul ; il n'y a
            // qu'à lui donner son chemin absolu, le PATH d'une app lancée depuis
            // le Finder ne contenant pas /opt/homebrew/bin.
            return LaunchPlan(
                command: try CommandBuilder.build(
                    shortcut, degradation: degradation, moshBinary: path
                ),
                notice: "mosh du système — les binaires publiés embarquent le leur."
            )

        case .bundled(let path):
            let alias = shortcut.connection.host
            let address = try await Self.resolveAddress(ofAlias: alias)
            return LaunchPlan(
                command: try Self.handshakeCommand(
                    for: shortcut, clientPath: path, address: address
                )
            )

        case .absent:
            throw MoshError.notInstalled
        }
    }

    // MARK: - La poignée de main

    /// Elle tient dans un script shell exécuté **par le PTY**, et non dans du
    /// Swift en arrière-plan : ssh doit pouvoir demander une phrase de passe ou
    /// une confirmation d'empreinte, et l'utilisateur doit la voir.
    static func handshakeCommand(
        for shortcut: Shortcut, clientPath: String, address: String
    ) throws -> String {
        let host = ShellQuoting.quoted(shortcut.connection.host)
        let remote = try CommandBuilder.remoteInvocation(shortcut)

        let serverCommand = ShellQuoting.singleQuoted(
            "mosh-server new -s -c 256 -l LANG=\(remoteLocale) -- " + remote
        )

        let steps = [
            "_latch=$(ssh \(host) -- \(serverCommand) | tr -d '\\r' | grep -m1 '^MOSH CONNECT ')",
            "[ -n \"$_latch\" ] || { echo 'latch: mosh-server n'\\''a pas répondu sur cet hôte.' >&2; exit 1; }",
            "_latch_port=${_latch#MOSH CONNECT }",
            "_latch_key=${_latch_port#* }",
            "_latch_port=${_latch_port%% *}",
            "MOSH_KEY=$_latch_key exec \(ShellQuoting.quoted(clientPath)) "
                + "\(ShellQuoting.quoted(address)) \"$_latch_port\"",
        ]
        return steps.joined(separator: "; ")
    }

    // MARK: - Résolution

    /// L'hôte réel derrière l'alias, puis son adresse numérique.
    static func resolveAddress(ofAlias alias: String) async throws -> String {
        let hostName = sshHostName(for: alias) ?? alias
        guard let address = numericAddress(of: hostName) else {
            throw MoshError.unresolvableHost(hostName)
        }
        return address
    }

    /// `ssh -G` rend la configuration effective, celle que ssh utiliserait
    /// vraiment. On ne réimplémente pas `~/.ssh/config`.
    static func sshHostName(for alias: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", alias]

        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[0] == "hostname" {
                return String(fields[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Une adresse déjà numérique traverse sans requête DNS.
    static func numericAddress(of host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            first.pointee.ai_addr,
            first.pointee.ai_addrlen,
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }
}
