//
//  CommandBuilderTests.swift
//  LatchTests
//
//  Les exemples de la SPEC §5, puis les cas tordus — ceux-là vérifiés en
//  faisant réellement traverser un `/bin/sh` à la commande construite, avec un
//  faux `tmux` qui imprime ce qu'il reçoit.
//

import XCTest

@testable import Latch

final class CommandBuilderTests: XCTestCase {

    // MARK: Fabrique

    private func shortcut(
        transport: Transport = .mosh,
        host: String = "billy",
        jumpHost: String? = nil,
        session: String = "api",
        directory: String? = nil,
        initial: InitialCommand = .shell,
        extraArgs: String? = nil,
        keepShell: Bool = false,
        controlMode: Bool = false,
        windows: [TmuxWindow] = [],
        preflight: [Preflight] = []
    ) -> Shortcut {
        Shortcut(
            name: "test",
            preflight: preflight,
            connection: Connection(
                transport: transport,
                host: host,
                jumpHost: jumpHost,
                tmuxSession: session,
                workingDirectory: directory,
                initialCommand: initial,
                extraArgs: extraArgs,
                keepShellOnExit: keepShell,
                controlMode: controlMode
            ),
            windows: windows
        )
    }

    // MARK: - Les exemples de la SPEC §5

    /// La SPEC écrit `mosh billy -- tmux new -A -s api -c ~/api 'claude; …'`.
    /// Cette forme ne peut pas marcher : mosh exécute la commande distante
    /// **sans shell**, donc personne ne développe `~/api` côté serveur — et le
    /// shell local, lui, le développerait avec le répertoire personnel du Mac.
    /// D'où le `sh -c` explicite, et seulement quand un chemin l'exige.
    func testMoshWithClaudeAndWorkingDirectory() throws {
        let command = try CommandBuilder.build(
            shortcut(transport: .mosh, directory: "~/api", initial: .claude, keepShell: true)
        )
        XCTAssertEqual(
            command,
            #"mosh billy -- sh -c "tmux new -A -s api -c ~/api 'claude; exec \$SHELL'""#
        )
    }

    func testSSHWithContinuedConversation() throws {
        let command = try CommandBuilder.build(
            shortcut(transport: .ssh, directory: "~/api", initial: .claudeContinue, keepShell: true)
        )
        XCTAssertEqual(
            command,
            #"ssh -t billy "tmux new -A -s api -c ~/api 'claude --continue; exec \$SHELL'""#
        )
    }

    func testSSHThroughAJumpHost() throws {
        let command = try CommandBuilder.build(shortcut(transport: .sshJump, jumpHost: "bastion"))
        XCTAssertEqual(command, #"ssh -t -J bastion billy "tmux new -A -s api""#)
    }

    func testMoshWithBareShellAndNoDirectory() throws {
        let command = try CommandBuilder.build(shortcut(transport: .mosh, session: "dev"))
        XCTAssertEqual(command, "mosh billy -- tmux new -A -s dev")
    }

    func testLocalSessionWithoutAConnection() throws {
        let command = try CommandBuilder.build(
            shortcut(transport: .local, host: "", session: "notes", directory: "~/notes")
        )
        XCTAssertEqual(command, "tmux new -A -s notes -c ~/notes")
    }

    // MARK: - Le préfixe tmux

    /// `-A` attache si la session existe, la crée sinon. Rien ne doit jamais
    /// tester son existence.
    func testAlwaysUsesAttachOrCreate() throws {
        for transport in Transport.allCases {
            let built = try CommandBuilder.build(
                shortcut(transport: transport, jumpHost: transport == .sshJump ? "bastion" : nil)
            )
            XCTAssertTrue(built.contains("tmux new -A -s api"), "transport \(transport) : \(built)")
            XCTAssertFalse(built.contains("has-session"), "transport \(transport) : \(built)")
        }
    }

    /// Sans `-t`, ssh n'alloue pas de TTY et tmux refuse de démarrer.
    func testSSHAlwaysAllocatesATTY() throws {
        XCTAssertTrue(try CommandBuilder.build(shortcut(transport: .ssh)).hasPrefix("ssh -t "))
        XCTAssertTrue(try CommandBuilder.build(
            shortcut(transport: .sshJump, jumpHost: "bastion")
        ).hasPrefix("ssh -t -J "))
    }

    func testKeepShellOnExitIsOptional() throws {
        let command = try CommandBuilder.build(
            shortcut(transport: .ssh, initial: .claude, keepShell: false)
        )
        XCTAssertEqual(command, #"ssh -t billy "tmux new -A -s api 'claude'""#)
    }

    func testExtraArgumentsRideWithTheInitialCommand() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .ssh,
                initial: .claude,
                extraArgs: "--model opus --permission-mode acceptEdits",
                keepShell: true
            )
        )
        XCTAssertEqual(
            command,
            #"ssh -t billy "tmux new -A -s api 'claude --model opus --permission-mode acceptEdits; exec \$SHELL'""#
        )
    }

    func testControlModeGoesBeforeTheSubcommand() throws {
        let command = try CommandBuilder.build(shortcut(transport: .ssh, controlMode: true))
        XCTAssertEqual(command, #"ssh -t billy "tmux -CC new -A -s api""#)
    }

    // MARK: - Fenêtres

    /// Les fenêtres naissent depuis la fenêtre 0, jamais d'un `\;` enchaîné sur
    /// la ligne tmux : vérifié sur un tmux 3.2a, une commande chaînée après
    /// `new -A` rejoue à chaque réattache et empile un doublon par connexion.
    func testWindowsAreCreatedFromInsideTheSessionAndNotChained() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .local,
                host: "",
                initial: .claude,
                keepShell: true,
                windows: [TmuxWindow(name: "logs", command: "journalctl -fu api")]
            )
        )
        XCTAssertFalse(command.contains(#"\;"#), "aucune commande tmux enchaînée : \(command)")

        let arguments = try ShellHarness.arguments(of: command)
        XCTAssertEqual(Array(arguments.prefix(4)), ["new", "-A", "-s", "api"])
        XCTAssertEqual(
            arguments.last,
            "tmux new-window -d -n logs 'journalctl -fu api'; claude; exec $SHELL"
        )
    }

    /// Sans commande initiale, créer les fenêtres remplace le shell par défaut
    /// de la fenêtre 0. Il faut le rendre, sinon la session meurt aussitôt.
    func testWindowsWithoutAnInitialCommandStillLeaveAShell() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .local,
                host: "",
                keepShell: false,
                windows: [TmuxWindow(name: "logs", command: "tail -f /var/log/syslog")]
            )
        )
        let arguments = try ShellHarness.arguments(of: command)
        XCTAssertEqual(arguments.last?.hasSuffix("; exec $SHELL"), true, "\(arguments)")
    }

    func testWindowOrderIsPreserved() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .local,
                host: "",
                windows: [
                    TmuxWindow(name: "logs", command: "tail -f a"),
                    TmuxWindow(name: "db", command: "psql"),
                ]
            )
        )
        let sessionCommand = try XCTUnwrap(ShellHarness.arguments(of: command).last)
        let logs = try XCTUnwrap(sessionCommand.range(of: "-n logs"))
        let database = try XCTUnwrap(sessionCommand.range(of: "-n db"))
        XCTAssertTrue(logs.lowerBound < database.lowerBound, sessionCommand)
    }

    // MARK: - Pré-vol

    func testFatalPreflightBreaksTheChain() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .ssh,
                preflight: [Preflight(label: "VPN", command: "scutil --nc status Home")]
            )
        )
        XCTAssertEqual(command, #"scutil --nc status Home && ssh -t billy "tmux new -A -s api""#)
    }

    /// Un pré-vol non fatal avertit et laisse passer. Le vérifier pour de vrai :
    /// on remplace la connexion par un `local`, on fait échouer le pré-vol, et
    /// tmux doit quand même être appelé.
    func testNonFatalPreflightNeverBlocksTheConnection() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .local,
                host: "",
                preflight: [Preflight(label: "Docker", command: "false", failureIsFatal: false)]
            )
        )
        let arguments = try ShellHarness.arguments(of: command)
        XCTAssertEqual(Array(arguments.prefix(4)), ["new", "-A", "-s", "api"])
    }

    func testFatalPreflightActuallyStopsTheConnection() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .local,
                host: "",
                preflight: [Preflight(label: "VPN", command: "false", failureIsFatal: true)]
            )
        )
        XCTAssertEqual(try ShellHarness.arguments(of: command), [], "tmux ne doit pas être appelé")
    }

    func testPreflightOrderIsPreserved() throws {
        let command = try CommandBuilder.build(
            shortcut(
                transport: .local,
                host: "",
                preflight: [
                    Preflight(label: "un", command: "echo un"),
                    Preflight(label: "deux", command: "echo deux"),
                ]
            )
        )
        XCTAssertEqual(command, "echo un && echo deux && tmux new -A -s api")
    }

    // MARK: - Commande personnalisée

    func testCustomCommandReplacesEverything() throws {
        var custom = shortcut(
            transport: .ssh,
            preflight: [Preflight(label: "VPN", command: "vpn up")]
        )
        custom.customCommand = "ssh autre-machine"
        XCTAssertEqual(try CommandBuilder.build(custom), "ssh autre-machine")
    }

    /// Une commande personnalisée court-circuite la validation : c'est
    /// l'utilisateur qui écrit, on ne discute pas ce qu'il a tapé.
    func testCustomCommandSkipsValidation() throws {
        var custom = shortcut(transport: .mosh, host: "", session: "", controlMode: true)
        custom.customCommand = "mosh ailleurs -- tmux a"
        XCTAssertEqual(try CommandBuilder.build(custom), "mosh ailleurs -- tmux a")
    }

    // MARK: - Validation

    func testControlModeWithMoshIsRefusedByTheModel() {
        let invalid = shortcut(transport: .mosh, controlMode: true)
        XCTAssertTrue(CommandBuilder.validate(invalid).contains { $0.field == .controlMode })
        XCTAssertThrowsError(try CommandBuilder.build(invalid))
    }

    func testControlModeIsAllowedWithSSH() {
        XCTAssertTrue(CommandBuilder.validate(shortcut(transport: .ssh, controlMode: true)).isEmpty)
    }

    func testMissingJumpHostIsRefused() {
        XCTAssertTrue(
            CommandBuilder.validate(shortcut(transport: .sshJump)).contains { $0.field == .jumpHost }
        )
    }

    func testJumpHostWithoutTheJumpTransportIsRefused() {
        XCTAssertTrue(
            CommandBuilder.validate(shortcut(transport: .ssh, jumpHost: "bastion"))
                .contains { $0.field == .jumpHost }
        )
    }

    func testSessionNameWithColonOrDotIsRefused() {
        for name in ["a:b", "a.b"] {
            XCTAssertTrue(
                CommandBuilder.validate(shortcut(session: name)).contains { $0.field == .tmuxSession },
                "session « \(name) »"
            )
        }
    }

    func testEmptyHostIsRefusedOnlyForRemoteTransports() {
        XCTAssertTrue(
            CommandBuilder.validate(shortcut(transport: .ssh, host: "")).contains { $0.field == .host }
        )
        XCTAssertTrue(CommandBuilder.validate(shortcut(transport: .local, host: "")).isEmpty)
    }

    func testExtraArgumentsWithoutACommandAreRefused() {
        XCTAssertTrue(
            CommandBuilder.validate(shortcut(initial: .shell, extraArgs: "--model opus"))
                .contains { $0.field == .extraArgs }
        )
    }

    func testEmptyWindowCommandIsRefused() {
        XCTAssertTrue(
            CommandBuilder.validate(shortcut(windows: [TmuxWindow(name: "logs", command: " ")]))
                .contains { $0.field == .window }
        )
    }

    // MARK: - Échappement, vérifié à travers un vrai shell

    func testSessionNameWithASpaceReachesTmuxIntact() throws {
        let command = try CommandBuilder.build(
            shortcut(transport: .local, host: "", session: "mes notes")
        )
        XCTAssertEqual(command, "tmux new -A -s 'mes notes'")
        XCTAssertEqual(try ShellHarness.arguments(of: command), ["new", "-A", "-s", "mes notes"])
    }

    func testDirectoryWithASpaceKeepsItsTildeOutsideTheQuotes() throws {
        let command = try CommandBuilder.build(
            shortcut(transport: .local, host: "", directory: "~/mes projets")
        )
        XCTAssertEqual(command, "tmux new -A -s api -c ~/'mes projets'")
        // Le tilde doit avoir été développé par le shell, pas laissé à tmux.
        XCTAssertEqual(
            try ShellHarness.arguments(of: command).last,
            NSHomeDirectory() + "/mes projets"
        )
    }

    func testDirectoryWithAnApostropheReachesTmuxIntact() throws {
        let command = try CommandBuilder.build(
            shortcut(transport: .local, host: "", directory: "/srv/l'api")
        )
        XCTAssertEqual(try ShellHarness.arguments(of: command).last, "/srv/l'api")
    }

    func testInitialCommandWithApostrophesAndDollarsReachesTmuxIntact() throws {
        let nasty = #"echo "c'est $USER" && rm -rf /tmp/rien"#
        let command = try CommandBuilder.build(
            shortcut(transport: .local, host: "", initial: .custom(nasty))
        )
        XCTAssertEqual(try ShellHarness.arguments(of: command).last, nasty)
    }

    /// Le cas qui casse tout si l'échappement est approximatif : la commande
    /// distante traverse le shell local entre guillemets doubles, puis le shell
    /// distant, puis le `sh -c` de tmux.
    func testNastyCommandSurvivesSSH() throws {
        let nasty = #"echo "total: $HOME" `hostname` 'et une apostrophe'"#
        let command = try CommandBuilder.build(
            shortcut(transport: .ssh, initial: .custom(nasty))
        )
        // Ce que ssh reçoit : l'hôte, puis la commande distante, littérale.
        let arguments = try ShellHarness.arguments(of: command)
        XCTAssertEqual(arguments.first, "-t")
        XCTAssertEqual(arguments[1], "billy")

        // Et ce que le shell distant en ferait, une fois relancé dessus.
        let remote = try XCTUnwrap(arguments.last)
        XCTAssertEqual(try ShellHarness.arguments(of: remote).last, nasty)
    }

    func testWindowCommandWithApostrophesReachesTheWindowIntact() throws {
        let nasty = #"grep "l'erreur" /var/log/api"#
        let command = try CommandBuilder.build(
            shortcut(
                transport: .local,
                host: "",
                windows: [TmuxWindow(name: "logs", command: nasty)]
            )
        )
        // Premier niveau : ce que tmux reçoit comme commande de session.
        let sessionCommand = try XCTUnwrap(ShellHarness.arguments(of: command).last)
        // Second niveau : ce que le `tmux new-window` interne reçoit à son tour.
        XCTAssertEqual(try ShellHarness.arguments(of: sessionCommand).last, nasty)
    }

    func testHostWithAnAtSignIsNotQuoted() throws {
        let command = try CommandBuilder.build(shortcut(transport: .ssh, host: "billy@192.168.1.37"))
        XCTAssertEqual(command, #"ssh -t billy@192.168.1.37 "tmux new -A -s api""#)
    }
}
