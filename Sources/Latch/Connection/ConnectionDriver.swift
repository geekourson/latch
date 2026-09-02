//
//  ConnectionDriver.swift
//  Latch
//
//  La couche du §3.2. « Chacune construit une commande et délègue à
//  PTYProcess » : c'est exactement ce que fait un driver ici — il produit un
//  plan de lancement, et le pseudo-terminal s'occupe du reste.
//
//  L'état, l'envoi et le redimensionnement ne sont pas redéclarés sur le
//  protocole : ils vivent déjà dans `PTYProcess` et `TerminalSession`, et les
//  dupliquer dans chaque driver ajouterait une couche sans ajouter de
//  comportement.
//

import Foundation

/// Ce qu'il faut pour lancer une connexion : une ligne de commande, et
/// éventuellement des variables d'environnement qui ne doivent surtout pas
/// finir sur la ligne de commande — une clé mosh est visible dans `ps`.
struct LaunchPlan: Equatable {
    var command: String
    var environment: [String: String] = [:]
    /// Ce que l'interface annonce si le transport a dû s'adapter.
    var notice: String?
}

protocol ConnectionDriver {
    /// Le transport que ce driver sait ouvrir.
    static var transport: Transport { get }

    /// Prépare le lancement. Peut faire un aller-retour réseau — la poignée de
    /// main de mosh en fait un — d'où l'asynchronisme.
    ///
    /// `toolPaths` porte les outils que la sonde a trouvés hors du `PATH` d'un
    /// shell non interactif : il faut les appeler par leur chemin absolu, sinon
    /// la commande échoue sur un « command not found » alors que le binaire est
    /// bien installé (§6).
    func plan(
        for shortcut: Shortcut,
        degradation: Degradation,
        toolPaths: [String: String]
    ) async throws -> LaunchPlan
}

extension ConnectionDriver {
    func plan(for shortcut: Shortcut, degradation: Degradation) async throws -> LaunchPlan {
        try await plan(for: shortcut, degradation: degradation, toolPaths: [:])
    }
}

// MARK: - Choix du driver

enum ConnectionDrivers {

    /// Le driver qui convient au transport demandé, une fois la cascade du §6
    /// appliquée.
    static func driver(
        for shortcut: Shortcut, degradation: Degradation
    ) -> ConnectionDriver {
        // Une commande personnalisée est lancée telle quelle : l'utilisateur
        // l'a écrite, aucun driver n'a à la réinterpréter.
        guard shortcut.customCommand == nil else { return LocalDriver() }

        switch shortcut.connection.transport {
        case .local:
            return LocalDriver()
        case .mosh:
            // Sans mosh-server en face, la cascade a déjà décidé : c'est ssh.
            return degradation == .none ? MoshDriver() : SSHDriver()
        case .ssh, .sshJump, .eternalTerminal:
            return SSHDriver()
        }
    }
}

// MARK: - Drivers simples

/// Pas de connexion : la commande tourne sur le Mac.
struct LocalDriver: ConnectionDriver {
    static let transport: Transport = .local

    func plan(
        for shortcut: Shortcut, degradation: Degradation, toolPaths: [String: String]
    ) async throws -> LaunchPlan {
        LaunchPlan(
            command: try CommandBuilder.build(
                shortcut, degradation: degradation, toolPaths: toolPaths
            )
        )
    }
}

/// `ssh`, `ssh -J` et Eternal Terminal : le binaire du système suffit, il est
/// livré avec macOS.
struct SSHDriver: ConnectionDriver {
    static let transport: Transport = .ssh

    func plan(
        for shortcut: Shortcut, degradation: Degradation, toolPaths: [String: String]
    ) async throws -> LaunchPlan {
        var plan = LaunchPlan(
            command: try CommandBuilder.build(
                shortcut, degradation: degradation, toolPaths: toolPaths
            )
        )
        if shortcut.connection.transport == .mosh, degradation.isDegraded {
            plan.notice = degradation.bannerTitle
        }
        return plan
    }
}
