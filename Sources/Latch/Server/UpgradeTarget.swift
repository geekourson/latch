//
//  UpgradeTarget.swift
//  Latch
//
//  Le panneau d'amélioration du §6 s'adresse à un hôte. Le Mac en est un :
//  sans tmux, une session locale se dégrade exactement comme une session
//  distante, et mérite le même diagnostic et la même commande d'installation.
//

import Foundation

enum UpgradeTarget: Identifiable, Equatable {
    case server(Server)
    /// Le Mac lui-même, pour les raccourcis en transport `local`.
    case localMac

    var id: String {
        switch self {
        case .server(let server): return server.id.uuidString
        case .localMac: return "local"
        }
    }

    var name: String {
        switch self {
        case .server(let server): return server.name
        case .localMac: return "Ce Mac"
        }
    }

    /// L'alias ssh, ou `nil` : rien à joindre, on est déjà là.
    var alias: String? {
        switch self {
        case .server(let server): return server.sshAlias
        case .localMac: return nil
        }
    }

    var isLocal: Bool { self == .localMac }

    /// La sonde de l'hôte. Celle du Mac est relevée à la demande : elle ne
    /// coûte que quelques accès disque, et ne se périme donc jamais.
    var probe: ProbeResult? {
        switch self {
        case .server(let server): return server.probe
        case .localMac: return LocalTools.probe()
        }
    }

    /// mosh n'a aucun sens sur une session qui n'ouvre pas de connexion.
    var wantsMosh: Bool { !isLocal }

    /// Où l'on exécute la commande d'installation proposée.
    var commandLocation: String {
        switch self {
        case .server(let server): return "À exécuter sur \(server.sshAlias)"
        case .localMac: return "À exécuter sur ce Mac"
        }
    }
}
