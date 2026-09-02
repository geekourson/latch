//
//  ServerUpgrade.swift
//  Latch
//
//  La cascade de dégradation et le contenu du panneau d'amélioration
//  (SPEC §6). Deux principes tiennent tout le fichier :
//
//    — la connexion réussit toujours, même dégradée. Aucune modale bloquante
//      avant d'avoir donné accès au serveur ;
//    — l'app ne lance aucune installation. Elle propose une commande exacte,
//      que l'utilisateur copie ou exécute lui-même dans un vrai TTY.
//

import Foundation

// MARK: - Cascade de dégradation

enum Degradation: Equatable {
    /// tmux + mosh : commande nominale.
    case none
    /// tmux seul : bascule sur `ssh -t`, bandeau non bloquant proposant mosh.
    case moshMissing
    /// Aucun des deux : `ssh -t` sur un shell nu, la session ne survivra pas.
    case tmuxMissing

    var isDegraded: Bool { self != .none }

    /// Une phrase, sans jargon, sur ce que ça coûte concrètement.
    var consequence: String {
        switch self {
        case .none:
            return "Tout est en place."
        case .moshMissing:
            return "Sans mosh, la session se fige après une mise en veille "
                + "et doit être relancée à la main."
        case .tmuxMissing:
            return "Sans tmux, la session ne survit pas à la fermeture de "
                + "l'onglet : le travail en cours est perdu."
        }
    }

    var bannerTitle: String {
        switch self {
        case .none: return ""
        case .moshMissing: return "Connecté en ssh — mosh n'est pas installé sur cet hôte"
        case .tmuxMissing: return "Shell nu — tmux n'est pas installé sur cet hôte"
        }
    }
}

enum ServerCapabilities {

    /// Ce que la sonde autorise. Une sonde absente est traitée comme un serveur
    /// complet : on n'ampute pas une connexion sur une ignorance.
    static func degradation(for probe: ProbeResult?) -> Degradation {
        guard let probe else { return .none }
        if !probe.hasTmux { return .tmuxMissing }
        if !probe.hasMoshServer { return .moshMissing }
        return .none
    }

    /// La dégradation applicable à un raccourci donné.
    ///
    /// Elle ne modifie jamais le modèle persisté : c'est une décision d'exécution,
    /// recalculée à chaque connexion. Une commande personnalisée n'est jamais
    /// retouchée — l'utilisateur l'a écrite, on ne la corrige pas dans son dos —
    /// et un raccourci local ne dépend d'aucune sonde.
    static func degradation(for shortcut: Shortcut, probe: ProbeResult?) -> Degradation {
        guard shortcut.customCommand == nil, shortcut.connection.transport.isRemote else {
            return .none
        }
        return degradation(for: probe)
    }
}

// MARK: - Panneau d'amélioration

/// Une ligne de diagnostic : `tmux 3.4 ✓`, `mosh-server absent ✗`.
struct ToolStatus: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var isPresent: Bool
    var version: String?
    /// Présent sur le disque, mais introuvable depuis un shell non interactif.
    var offPathAt: String?

    var isOffPath: Bool { offPathAt != nil }

    var summary: String {
        guard isPresent else { return "\(name) absent" }
        if isOffPath { return "\(name) hors PATH" }
        if let version { return "\(name) \(version)" }
        return name
    }
}

/// Tout ce que le panneau du §6 affiche, calculé d'un coup à partir de la
/// sonde. Aucune de ces commandes n'est exécutée par Latch.
struct UpgradePlan: Equatable {
    var diagnostics: [ToolStatus] = []
    var degradation: Degradation = .none
    /// Uniquement les paquets réellement manquants : si seul mosh manque, la
    /// commande ne réinstalle pas tmux.
    var missingPackages: [String] = []
    /// `nil` quand la distribution est inconnue : on n'invente pas de commande.
    var packageCommand: String?
    /// Affichée seulement si mosh fait partie des paquets à installer.
    var firewallCommand: String?
    /// Claude Code n'est dans aucun gestionnaire de paquets : sa ligne est
    /// séparée, et surtout **sans sudo** — l'installeur officiel refuse de
    /// tourner sous sudo et pose le binaire dans `$HOME/.local/bin`.
    var claudeCommand: String?
    /// Les outils installés mais invisibles d'un shell non interactif : il n'y
    /// a rien à installer pour eux, seulement un `PATH` à corriger.
    var offPathTools: [String: String] = [:]
    var distributionName: String?
    var hasKnownDistribution: Bool { packageCommand != nil }

    var needsAnything: Bool {
        !missingPackages.isEmpty || claudeCommand != nil || !offPathTools.isEmpty
    }
}

enum ServerUpgradePlanner {

    static let claudeInstallCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let documentationURL = URL(string: "https://github.com/tmux/tmux/wiki/Installing")!

    /// Le §6 mentionne `claude` dans la sonde mais pas dans le tableau des
    /// commandes. On le traite ici comme un troisième outil, avec sa propre
    /// ligne, parce qu'un utilisateur de Latch qui n'a pas Claude Code sur son
    /// serveur perd la moitié de l'intérêt de l'app.
    static func plan(for probe: ProbeResult?, wantsMosh: Bool = true) -> UpgradePlan {
        guard let probe else { return UpgradePlan() }

        var plan = UpgradePlan()
        plan.degradation = ServerCapabilities.degradation(for: probe)
        plan.diagnostics = [
            ToolStatus(
                name: "tmux", isPresent: probe.hasTmux, version: probe.tmuxVersion,
                offPathAt: probe.offPathTools["tmux"]
            ),
            ToolStatus(
                name: "mosh-server", isPresent: probe.hasMoshServer,
                offPathAt: probe.offPathTools["mosh-server"]
            ),
            ToolStatus(
                name: "claude", isPresent: probe.hasClaude,
                offPathAt: probe.offPathTools["claude"]
            ),
        ]
        plan.offPathTools = probe.offPathTools

        if !probe.hasTmux { plan.missingPackages.append("tmux") }
        if wantsMosh, !probe.hasMoshServer { plan.missingPackages.append("mosh") }

        if !plan.missingPackages.isEmpty {
            plan.packageCommand = installCommand(osID: probe.osID, packages: plan.missingPackages)
        }
        if plan.missingPackages.contains("mosh") {
            plan.firewallCommand = "sudo ufw allow 60000:61000/udp"
        }
        if !probe.hasClaude {
            plan.claudeCommand = claudeInstallCommand
        }
        plan.distributionName = probe.osID

        return plan
    }

    // MARK: Tableau du §6

    /// La commande exacte, construite à partir du champ `ID` de
    /// `/etc/os-release`. Une distribution inconnue ne produit rien : on
    /// affiche alors les paquets requis et un champ libre.
    static func installCommand(osID: String?, packages: [String]) -> String? {
        guard !packages.isEmpty else { return nil }
        let identifier = (osID ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { return nil }
        let list = packages.joined(separator: " ")

        switch identifier {
        case "debian", "ubuntu", "raspbian", "linuxmint", "pop":
            return "sudo apt install -y \(list)"
        case "fedora", "rhel", "centos", "rocky", "almalinux":
            return "sudo dnf install -y \(list)"
        case "arch", "manjaro", "endeavouros":
            return "sudo pacman -S --noconfirm \(list)"
        case "alpine":
            return "sudo apk add \(list)"
        case "sles":
            return "sudo zypper install -y \(list)"
        case "freebsd":
            return "sudo pkg install -y \(list)"
        default:
            // `opensuse-leap`, `opensuse-tumbleweed`… le §6 écrit `opensuse*`.
            if identifier.hasPrefix("opensuse") { return "sudo zypper install -y \(list)" }
            return nil
        }
    }

    /// Le support n°1 attendu (§6) : un outil qui existe en session mais que la
    /// sonde ne voit pas, parce que le `PATH` est défini dans `~/.bashrc`, lu
    /// seulement par les shells interactifs.
    static let nonInteractivePathHint =
        "Si ces outils fonctionnent quand tu te connectes à la main, c'est que "
        + "le PATH est défini dans ~/.bashrc, que les shells non interactifs ne "
        + "lisent pas. Déplace-le dans ~/.profile ou ~/.zshenv."
}
