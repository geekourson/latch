//
//  ServerUpgradeTests.swift
//  LatchTests
//
//  La sonde, la cascade de dégradation et le panneau d'amélioration (SPEC §6).
//

import XCTest

@testable import Latch

final class ServerProbeTests: XCTestCase {

    /// La sortie réelle du serveur de référence : tmux présent, ni mosh-server
    /// ni claude, Ubuntu.
    func testParsesTheReferenceServer() {
        let result = ServerProbe.parse("/usr/bin/tmux\ntmux 3.2a\nubuntu\n")
        XCTAssertTrue(result.hasTmux)
        XCTAssertFalse(result.hasMoshServer)
        XCTAssertFalse(result.hasClaude)
        XCTAssertEqual(result.tmuxVersion, "3.2a")
        XCTAssertEqual(result.osID, "ubuntu")
    }

    func testParsesAFullyEquippedServer() {
        let result = ServerProbe.parse(
            """
            /usr/bin/tmux
            /usr/bin/mosh-server
            /home/alex/.local/bin/claude
            tmux 3.4
            debian
            """
        )
        XCTAssertTrue(result.hasTmux)
        XCTAssertTrue(result.hasMoshServer)
        XCTAssertTrue(result.hasClaude)
        XCTAssertEqual(result.tmuxVersion, "3.4")
        XCTAssertEqual(result.osID, "debian")
    }

    func testParsesAnEmptyServer() {
        let result = ServerProbe.parse("\n")
        XCTAssertFalse(result.hasTmux)
        XCTAssertNil(result.osID)
    }

    /// Certaines distributions écrivent `ID="rocky"` : le shell rend la valeur
    /// sans guillemets, mais mieux vaut ne pas en dépendre.
    func testStripsQuotesAroundTheDistributionIdentifier() {
        XCTAssertEqual(ServerProbe.parse("\"rocky\"\n").osID, "rocky")
    }

    /// Un seul aller-retour, c'est la contrainte du §6.
    func testProbeAsksEverythingInOneCommand() {
        XCTAssertTrue(ServerProbe.remoteScript.contains("command -v tmux mosh-server claude"))
        XCTAssertTrue(ServerProbe.remoteScript.contains("tmux -V"))
        XCTAssertTrue(ServerProbe.remoteScript.contains("/etc/os-release"))
    }
}

final class DegradationTests: XCTestCase {

    private func shortcut(transport: Transport = .mosh) -> Shortcut {
        Shortcut(
            name: "api",
            connection: Connection(transport: transport, host: "alex", tmuxSession: "api")
        )
    }

    private func probe(tmux: Bool, mosh: Bool) -> ProbeResult {
        ProbeResult(hasTmux: tmux, tmuxVersion: tmux ? "3.2a" : nil, hasMoshServer: mosh)
    }

    func testFullyEquippedServerIsNotDegraded() {
        XCTAssertEqual(ServerCapabilities.degradation(for: probe(tmux: true, mosh: true)), .none)
    }

    func testTmuxWithoutMoshFallsBackToSSH() throws {
        let degradation = ServerCapabilities.degradation(for: probe(tmux: true, mosh: false))
        XCTAssertEqual(degradation, .moshMissing)

        let command = try CommandBuilder.build(shortcut(transport: .mosh), degradation: degradation)
        XCTAssertEqual(command, #"ssh -t alex "tmux new -A -s api""#)
    }

    /// Sans tmux, on ouvre un shell nu — et on prévient que la session ne
    /// survivra pas. La connexion, elle, réussit quand même.
    func testNoTmuxOpensABareShell() throws {
        let degradation = ServerCapabilities.degradation(for: probe(tmux: false, mosh: false))
        XCTAssertEqual(degradation, .tmuxMissing)

        let command = try CommandBuilder.build(shortcut(transport: .mosh), degradation: degradation)
        XCTAssertEqual(command, "ssh -t alex")
        XCTAssertFalse(command.contains("tmux"))
    }

    func testJumpHostSurvivesTheBareShellFallback() throws {
        var jumped = shortcut(transport: .sshJump)
        jumped.connection.jumpHost = "bastion"
        let command = try CommandBuilder.build(jumped, degradation: .tmuxMissing)
        XCTAssertEqual(command, "ssh -t -J bastion alex")
    }

    /// Sans sonde, on ne dégrade rien : on n'ampute pas une connexion sur une
    /// ignorance.
    func testAnUnprobedServerIsAssumedComplete() {
        XCTAssertEqual(ServerCapabilities.degradation(for: nil), .none)
    }

    func testCustomCommandsAreNeverDegraded() {
        var custom = shortcut()
        custom.customCommand = "mosh ailleurs -- tmux a"
        XCTAssertEqual(
            ServerCapabilities.degradation(for: custom, probe: probe(tmux: false, mosh: false)),
            .none
        )
    }

    /// Le Mac est un hôte comme un autre : sans tmux, un raccourci local
    /// échouait sur « /bin/sh: tmux: command not found ». Il dégrade
    /// maintenant vers un shell, comme n'importe quel serveur.
    func testLocalShortcutsAreDegradedToo() throws {
        let degradation = ServerCapabilities.degradation(
            for: shortcut(transport: .local), probe: probe(tmux: false, mosh: false)
        )
        XCTAssertEqual(degradation, .tmuxMissing)

        var local = shortcut(transport: .local)
        local.connection.host = ""
        XCTAssertEqual(
            try CommandBuilder.build(local, degradation: degradation),
            "exec $SHELL"
        )
    }

    /// Avec tmux, rien ne change : mosh n'a aucun sens en local et ne doit pas
    /// déclencher de bandeau.
    func testALocalShortcutWithTmuxIsNotDegraded() {
        XCTAssertEqual(
            ServerCapabilities.degradation(
                for: shortcut(transport: .local), probe: probe(tmux: true, mosh: true)
            ),
            .none
        )
    }

    /// Le pré-vol reste devant, même dégradé.
    func testPreflightSurvivesDegradation() throws {
        var withPreflight = shortcut(transport: .mosh)
        withPreflight.preflight = [Preflight(label: "VPN", command: "vpn up")]
        let command = try CommandBuilder.build(withPreflight, degradation: .moshMissing)
        XCTAssertTrue(command.hasPrefix("vpn up && ssh -t "), command)
    }
}

final class UpgradePlanTests: XCTestCase {
    /// Ces tests comparent des textes français. La langue du système de la
    /// machine qui les exécute ne doit rien y changer : la CI tourne en
    /// anglais, et sans ça elle voyait passer les traductions.
    override func setUp() {
        super.setUp()
        Localization.apply(.french)
    }


    private func probe(
        tmux: Bool = true, mosh: Bool = true, claude: Bool = true, osID: String? = "ubuntu"
    ) -> ProbeResult {
        ProbeResult(
            hasTmux: tmux,
            tmuxVersion: tmux ? "3.2a" : nil,
            hasMoshServer: mosh,
            hasClaude: claude,
            osID: osID
        )
    }

    // MARK: Le tableau des distributions

    func testEveryDistributionFamilyOfTheSpec() {
        let expectations: [(String, String)] = [
            ("debian", "sudo apt install -y tmux mosh"),
            ("ubuntu", "sudo apt install -y tmux mosh"),
            ("raspbian", "sudo apt install -y tmux mosh"),
            ("linuxmint", "sudo apt install -y tmux mosh"),
            ("pop", "sudo apt install -y tmux mosh"),
            ("fedora", "sudo dnf install -y tmux mosh"),
            ("rhel", "sudo dnf install -y tmux mosh"),
            ("centos", "sudo dnf install -y tmux mosh"),
            ("rocky", "sudo dnf install -y tmux mosh"),
            ("almalinux", "sudo dnf install -y tmux mosh"),
            ("arch", "sudo pacman -S --noconfirm tmux mosh"),
            ("manjaro", "sudo pacman -S --noconfirm tmux mosh"),
            ("endeavouros", "sudo pacman -S --noconfirm tmux mosh"),
            ("alpine", "sudo apk add tmux mosh"),
            ("opensuse-leap", "sudo zypper install -y tmux mosh"),
            ("opensuse-tumbleweed", "sudo zypper install -y tmux mosh"),
            ("sles", "sudo zypper install -y tmux mosh"),
            ("freebsd", "sudo pkg install -y tmux mosh"),
        ]

        for (identifier, expected) in expectations {
            XCTAssertEqual(
                ServerUpgradePlanner.installCommand(osID: identifier, packages: ["tmux", "mosh"]),
                expected,
                "distribution « \(identifier) »"
            )
        }
    }

    /// Distribution inconnue ou absente : pas de commande inventée.
    func testUnknownDistributionProducesNoCommand() {
        XCTAssertNil(ServerUpgradePlanner.installCommand(osID: "plan9", packages: ["tmux"]))
        XCTAssertNil(ServerUpgradePlanner.installCommand(osID: nil, packages: ["tmux"]))
        XCTAssertNil(ServerUpgradePlanner.installCommand(osID: "", packages: ["tmux"]))
    }

    /// « N'inclure que les paquets réellement manquants. Si seul mosh manque,
    /// la commande ne doit pas réinstaller tmux. »
    func testOnlyMissingPackagesAreInstalled() {
        let plan = ServerUpgradePlanner.plan(for: probe(tmux: true, mosh: false))
        XCTAssertEqual(plan.missingPackages, ["mosh"])
        XCTAssertEqual(plan.packageCommand, "sudo apt install -y mosh")
    }

    func testNothingMissingProducesNoCommand() {
        let plan = ServerUpgradePlanner.plan(for: probe())
        XCTAssertTrue(plan.missingPackages.isEmpty)
        XCTAssertNil(plan.packageCommand)
        XCTAssertNil(plan.firewallCommand)
        XCTAssertNil(plan.claudeCommand)
        XCTAssertFalse(plan.needsAnything)
    }

    // MARK: Pare-feu

    /// La note pare-feu n'apparaît que si mosh est à installer.
    func testFirewallNoteOnlyWhenMoshIsInstalled() {
        XCTAssertEqual(
            ServerUpgradePlanner.plan(for: probe(mosh: false)).firewallCommand,
            "sudo ufw allow 60000:61000/udp"
        )
        XCTAssertNil(ServerUpgradePlanner.plan(for: probe(tmux: false, mosh: true)).firewallCommand)
    }

    // MARK: Diagnostic

    func testDiagnosticsCarryVersionsAndAbsences() {
        let plan = ServerUpgradePlanner.plan(for: probe(tmux: true, mosh: false, claude: false))
        XCTAssertEqual(plan.diagnostics.map(\.summary), ["tmux 3.2a", "mosh-server absent", "claude absent"])
    }

    // MARK: Claude Code

    /// Claude Code n'est dans aucun gestionnaire de paquets : sa ligne est
    /// séparée, et **sans sudo** — l'installeur officiel refuse de tourner sous
    /// sudo et pose le binaire dans `$HOME/.local/bin`.
    func testClaudeHasItsOwnLineWithoutSudo() {
        let plan = ServerUpgradePlanner.plan(for: probe(claude: false))
        let command = try? XCTUnwrap(plan.claudeCommand)
        XCTAssertEqual(command, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertFalse(plan.claudeCommand?.contains("sudo") ?? true)
        XCTAssertFalse(plan.missingPackages.contains("claude"))
    }

    func testClaudeIsNotOfferedWhenAlreadyThere() {
        XCTAssertNil(ServerUpgradePlanner.plan(for: probe(claude: true)).claudeCommand)
    }

    // MARK: Rien sans sonde

    func testNoProbeMeansNothingToPropose() {
        let plan = ServerUpgradePlanner.plan(for: nil)
        XCTAssertTrue(plan.diagnostics.isEmpty)
        XCTAssertFalse(plan.needsAnything)
    }
}

// MARK: - Le piège du §6, constaté sur un vrai serveur

final class OffPathToolTests: XCTestCase {
    /// Ces tests comparent des textes français. La langue du système de la
    /// machine qui les exécute ne doit rien y changer : la CI tourne en
    /// anglais, et sans ça elle voyait passer les traductions.
    override func setUp() {
        super.setUp()
        Localization.apply(.french)
    }


    /// La sortie réelle du serveur de référence : `claude` est installé dans
    /// `~/.local/bin`, que seul `~/.bashrc` ajoute au PATH — donc invisible
    /// d'un shell non interactif, donc invisible de `command -v`.
    private let realOutput = """
        /usr/bin/tmux
        tmux 3.2a
        ubuntu
        LATCH_OFFPATH claude /home/alex/.local/bin/claude
        """

    func testAToolFoundOnlyOffPathCountsAsPresent() {
        let result = ServerProbe.parse(realOutput)
        XCTAssertTrue(result.hasClaude, "claude est installé, même si command -v l'ignore")
        XCTAssertTrue(result.isOffPath("claude"))
        XCTAssertEqual(result.offPathTools["claude"], "/home/alex/.local/bin/claude")
        XCTAssertFalse(result.isOffPath("tmux"), "tmux, lui, est bien sur le PATH")
    }

    /// Le contraire du bug : proposer de réinstaller ce qui est déjà là.
    func testAnOffPathToolIsNotOfferedForInstallation() {
        let plan = ServerUpgradePlanner.plan(for: ServerProbe.parse(realOutput))
        XCTAssertNil(plan.claudeCommand, "claude est là, on ne propose pas de le réinstaller")
        XCTAssertEqual(plan.offPathTools["claude"], "/home/alex/.local/bin/claude")
        XCTAssertTrue(plan.diagnostics.contains { $0.name == "claude" && $0.summary == "claude hors PATH" })
    }

    /// Un outil trouvé des deux façons n'est pas « hors PATH ».
    func testAToolOnThePathIsNeverMarkedOffPath() {
        let result = ServerProbe.parse(
            """
            /usr/bin/tmux
            /home/alex/.local/bin/claude
            LATCH_OFFPATH claude /home/alex/.local/bin/claude
            """
        )
        XCTAssertTrue(result.hasClaude)
        XCTAssertFalse(result.isOffPath("claude"))
    }

    /// Toujours un seul aller-retour, comme l'exige le §6.
    func testTheProbeStillFitsInOneCommand() {
        XCTAssertFalse(ServerProbe.remoteScript.contains("\n"))
        XCTAssertTrue(ServerProbe.remoteScript.contains("command -v tmux mosh-server claude"))
        XCTAssertTrue(ServerProbe.remoteScript.contains("$HOME/.local/bin"))
    }

    // MARK: La commande produite

    private func claudeShortcut() -> Shortcut {
        Shortcut(
            name: "api",
            connection: Connection(
                transport: .ssh, host: "alex", tmuxSession: "api",
                initialCommand: .claudeContinue, keepShellOnExit: false
            )
        )
    }

    /// Sans ça, la session s'ouvrirait sur « claude: command not found » alors
    /// que le binaire est installé : tmux lance sa commande via un `sh -c`, qui
    /// est tout aussi non interactif que la sonde.
    func testAnOffPathToolIsCalledByItsAbsolutePath() throws {
        let command = try CommandBuilder.build(
            claudeShortcut(),
            toolPaths: ["claude": "/home/alex/.local/bin/claude"]
        )
        XCTAssertTrue(command.contains("/home/alex/.local/bin/claude --continue"), command)
        XCTAssertFalse(command.contains("'claude --continue'"), command)
    }

    /// Les arguments sont préservés, seul le nom du programme est remplacé.
    func testOnlyTheProgramNameIsSubstituted() throws {
        var shortcut = claudeShortcut()
        shortcut.connection.extraArgs = "--model opus"
        let command = try CommandBuilder.build(
            shortcut, toolPaths: ["claude": "/opt/claude"]
        )
        XCTAssertTrue(command.contains("/opt/claude --continue --model opus"), command)
    }

    func testTmuxItselfCanBeOffPath() throws {
        let command = try CommandBuilder.build(
            claudeShortcut(), toolPaths: ["tmux": "/usr/local/bin/tmux"]
        )
        XCTAssertTrue(command.contains("/usr/local/bin/tmux new -A -s api"), command)
    }

    /// Sans chemin connu, rien ne change : la commande reste celle du §5.
    func testNoToolPathsMeansNoSubstitution() throws {
        XCTAssertEqual(
            try CommandBuilder.build(claudeShortcut()),
            #"ssh -t alex "tmux new -A -s api 'claude --continue'""#
        )
    }
}

// MARK: - Le Mac comme hôte du §6

final class LocalUpgradeTests: XCTestCase {

    /// Homebrew n'a pas de « -y » — il n'attend rien — et surtout pas de sudo :
    /// brew refuse de tourner en root.
    func testMacOSJoinsTheDistributionTable() {
        XCTAssertEqual(
            ServerUpgradePlanner.installCommand(osID: "macos", packages: ["tmux"]),
            "brew install tmux"
        )
        XCTAssertFalse(
            ServerUpgradePlanner.installCommand(osID: "macos", packages: ["tmux"])?
                .contains("sudo") ?? true
        )
    }

    /// mosh n'a aucun sens sur une session qui n'ouvre pas de connexion : la
    /// commande locale ne doit proposer que tmux.
    func testALocalPlanNeverOffersMosh() {
        let probe = ProbeResult(hasTmux: false, hasMoshServer: true, osID: "macos")
        let plan = ServerUpgradePlanner.plan(for: probe, wantsMosh: false)

        XCTAssertEqual(plan.missingPackages, ["tmux"])
        XCTAssertEqual(plan.packageCommand, "brew install tmux")
        XCTAssertNil(plan.firewallCommand, "pas de pare-feu à ouvrir pour une session locale")
    }

    func testTheTargetKnowsWhereItsCommandRuns() {
        XCTAssertTrue(UpgradeTarget.localMac.isLocal)
        XCTAssertNil(UpgradeTarget.localMac.alias)
        XCTAssertFalse(UpgradeTarget.localMac.wantsMosh)
        XCTAssertEqual(UpgradeTarget.localMac.commandLocation, "À exécuter sur ce Mac")

        let server = Server(name: "alex", sshAlias: "alex")
        XCTAssertEqual(UpgradeTarget.server(server).alias, "alex")
        XCTAssertTrue(UpgradeTarget.server(server).wantsMosh)
    }

    /// La sonde du Mac est relevée à la demande : elle ne se périme jamais et
    /// n'a rien à invalider.
    func testTheLocalTargetProbesOnDemand() {
        XCTAssertNotNil(UpgradeTarget.localMac.probe)
        XCTAssertEqual(UpgradeTarget.localMac.probe?.osID, "macos")
    }
}
