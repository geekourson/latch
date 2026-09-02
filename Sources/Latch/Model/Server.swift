//
//  Server.swift
//  Latch
//
//  Les serveurs sont séparés des raccourcis (SPEC §4) : plusieurs raccourcis
//  partagent un hôte. Le lien se fait par l'alias ssh.
//

import Foundation

struct Server: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// « billy »
    var name: String
    /// Entrée `Host` de `~/.ssh/config`.
    var sshAlias: String
    /// Mis en cache, rempli par la sonde du §6 (v0.3).
    var probe: ProbeResult?
    var probedAt: Date?
    /// « Ne plus proposer d'améliorer cet hôte » (§6). Un serveur géré par
    /// quelqu'un d'autre ne sera jamais amélioré.
    var skipUpgradePrompt: Bool = false

    /// La sonde expire au bout de sept jours.
    var probeIsStale: Bool {
        guard let probedAt else { return true }
        return Date().timeIntervalSince(probedAt) > 7 * 24 * 3600
    }
}

/// Résultat de la sonde du §6. La sonde elle-même arrive en v0.3 ; le type est
/// ici parce que `Server` le porte et que le fichier JSON doit déjà savoir le
/// relire.
struct ProbeResult: Codable, Equatable {
    var hasTmux: Bool = false
    var tmuxVersion: String?
    var hasMoshServer: Bool = false
    var hasClaude: Bool = false
    /// Champ `ID` de `/etc/os-release`.
    var osID: String?
}
