//
//  ConnectionState.swift
//  Latch
//
//  L'état d'une connexion, tel que le décrit le §3.2. C'est ce que l'onglet, la
//  barre latérale et la barre d'état lisent — jamais l'état brut du PTY, qui ne
//  sait pas ce qu'est une reconnexion.
//

import Foundation

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    /// Le Mac s'est endormi, ou le process est mort et on va le relancer.
    case reconnecting(attempt: Int)
    /// Connecté, mais pas comme demandé (§6).
    case degraded(reason: String)
    /// Abandonné : on attend une action de l'utilisateur.
    case failed(reason: String)

    var isLive: Bool {
        switch self {
        case .connected, .degraded: return true
        case .idle, .connecting, .reconnecting, .failed: return false
        }
    }

    var isTrying: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "en attente"
        case .connecting: return "connexion…"
        case .connected: return "latched on"
        case .reconnecting(let attempt):
            return attempt <= 1 ? "reconnexion…" : "reconnexion… (\(attempt))"
        case .degraded: return "latched on · dégradé"
        case .failed: return "échec"
        }
    }
}
