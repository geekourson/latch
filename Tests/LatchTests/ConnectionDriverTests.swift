//
//  ConnectionDriverTests.swift
//  LatchTests
//
//  La couche du §3.2 et le binaire mosh du §7.
//

import Foundation
import XCTest

@testable import Latch

private func shortcut(
    transport: Transport = .mosh,
    host: String = "billy",
    session: String = "api",
    directory: String? = nil,
    initial: InitialCommand = .shell,
    keepShell: Bool = false
) -> Shortcut {
    Shortcut(
        name: "test",
        connection: Connection(
            transport: transport,
            host: host,
            tmuxSession: session,
            workingDirectory: directory,
            initialCommand: initial,
            keepShellOnExit: keepShell
        )
    )
}

final class ConnectionDriverSelectionTests: XCTestCase {

    func testEachTransportGetsItsDriver() {
        XCTAssertTrue(
            ConnectionDrivers.driver(for: shortcut(transport: .local), degradation: .none)
                is LocalDriver
        )
        XCTAssertTrue(
            ConnectionDrivers.driver(for: shortcut(transport: .mosh), degradation: .none)
                is MoshDriver
        )
        for transport in [Transport.ssh, .sshJump, .eternalTerminal] {
            XCTAssertTrue(
                ConnectionDrivers.driver(for: shortcut(transport: transport), degradation: .none)
                    is SSHDriver,
                "transport \(transport)"
            )
        }
    }

    /// Sans mosh-server en face, la cascade du §6 a déjà tranché : c'est ssh,
    /// et il ne sert à rien de réveiller le driver mosh.
    func testDegradedMoshFallsToTheSSHDriver() {
        XCTAssertTrue(
            ConnectionDrivers.driver(for: shortcut(transport: .mosh), degradation: .moshMissing)
                is SSHDriver
        )
    }

    /// Une commande personnalisée n'est réinterprétée par aucun driver.
    func testCustomCommandGoesStraightThrough() async throws {
        var custom = shortcut(transport: .mosh)
        custom.customCommand = "ssh ailleurs"
        let driver = ConnectionDrivers.driver(for: custom, degradation: .none)
        XCTAssertTrue(driver is LocalDriver)

        let plan = try await driver.plan(for: custom, degradation: .none)
        XCTAssertEqual(plan.command, "ssh ailleurs")
    }

    func testLocalDriverBuildsTheCommand() async throws {
        let plan = try await LocalDriver().plan(
            for: shortcut(transport: .local, host: "", session: "notes"),
            degradation: .none
        )
        XCTAssertEqual(plan.command, "tmux new -A -s notes")
        XCTAssertTrue(plan.environment.isEmpty)
    }

    func testSSHDriverAnnouncesADegradedMosh() async throws {
        let plan = try await SSHDriver().plan(
            for: shortcut(transport: .mosh), degradation: .moshMissing
        )
        XCTAssertEqual(plan.command, #"ssh -t billy "tmux new -A -s api""#)
        XCTAssertNotNil(plan.notice)
    }
}

final class MoshClientTests: XCTestCase {

    /// On ne consulte pas le `PATH` : une app lancée depuis le Finder hérite de
    /// celui de launchd, qui ne contient pas /opt/homebrew/bin.
    func testSearchesAbsolutePathsOnly() {
        for path in MoshClient.systemSearchPaths {
            XCTAssertTrue(path.hasPrefix("/"), path)
        }
        XCTAssertTrue(MoshClient.systemSearchPaths.contains("/opt/homebrew/bin/mosh"))
    }

    func testBundledClientSitsNextToTheExecutable() throws {
        let path = try XCTUnwrap(MoshClient.bundledPath)
        XCTAssertTrue(path.hasSuffix("/mosh-client"), path)
    }

    func testAbsentIsNotAvailable() {
        XCTAssertFalse(MoshClient.Availability.absent.isAvailable)
        XCTAssertTrue(MoshClient.Availability.bundled(path: "/x").isAvailable)
        XCTAssertTrue(MoshClient.Availability.system(path: "/x").isAvailable)
    }
}

final class MoshDriverTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-mosh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Sans mosh nulle part, on le dit clairement plutôt que de lancer une
    /// commande qui échouera sans expliquer pourquoi.
    func testAbsentMoshIsRefusedWithAUsefulMessage() async {
        var driver = MoshDriver()
        driver.availability = .absent
        do {
            _ = try await driver.plan(for: shortcut(), degradation: .none)
            XCTFail("le driver aurait dû refuser")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("brew install mosh"))
        }
    }

    /// Avec le `mosh` du système, on lui donne son chemin absolu — pas son nom.
    func testSystemMoshIsInvokedByAbsolutePath() async throws {
        var driver = MoshDriver()
        driver.availability = .system(path: "/opt/homebrew/bin/mosh")

        let plan = try await driver.plan(for: shortcut(session: "dev"), degradation: .none)
        XCTAssertEqual(plan.command, "/opt/homebrew/bin/mosh billy -- tmux new -A -s dev")
        XCTAssertNotNil(plan.notice, "l'interface doit dire qu'on n'utilise pas le binaire embarqué")
    }

    // MARK: La poignée de main du binaire embarqué

    /// Le vrai test : on exécute le script de poignée de main avec un faux
    /// `ssh` qui répond comme mosh-server, et un faux client qui imprime ce
    /// qu'il a reçu. C'est la seule façon de vérifier les découpages `${…#…}`.
    func testHandshakeParsesTheMoshConnectLine() throws {
        try ShellHarness.writeStub(
            named: "ssh",
            body: "echo 'MOSH CONNECT 60001 6WsCM6HZKJXA1uZbEA6Bcw'",
            in: directory
        )
        try ShellHarness.writeStub(
            named: "fake-client",
            body: #"printf '%s|%s|%s' "$1" "$2" "$MOSH_KEY""#,
            in: directory
        )

        let command = try MoshDriver.handshakeCommand(
            for: shortcut(directory: "~/api", initial: .claude, keepShell: true),
            clientPath: directory.appendingPathComponent("fake-client").path,
            address: "192.168.1.37"
        )
        let output = try ShellHarness.run(command, prependingToPath: directory)

        XCTAssertEqual(
            String(decoding: output, as: UTF8.self)
                .split(separator: "\n").last.map(String.init),
            "192.168.1.37|60001|6WsCM6HZKJXA1uZbEA6Bcw"
        )
    }

    /// La clé de session ne doit jamais apparaître sur la ligne de commande :
    /// n'importe quel `ps` de la machine la lirait.
    func testTheSessionKeyNeverReachesTheCommandLine() throws {
        let command = try MoshDriver.handshakeCommand(
            for: shortcut(),
            clientPath: "/Applications/Latch.app/Contents/MacOS/mosh-client",
            address: "192.168.1.37"
        )
        XCTAssertTrue(command.contains("MOSH_KEY=$_latch_key exec "), command)
        XCTAssertFalse(command.contains("env MOSH_KEY"), "un `env` exposerait la clé dans ps")
    }

    /// mosh-server veut une locale UTF-8, et celle de l'hôte n'a aucune raison
    /// d'en être une.
    func testHandshakeForcesAUTF8LocaleOnTheServer() throws {
        let command = try MoshDriver.handshakeCommand(
            for: shortcut(), clientPath: "/x/mosh-client", address: "10.0.0.1"
        )
        XCTAssertTrue(command.contains("mosh-server new -s -c 256 -l LANG=en_US.UTF-8 --"), command)
    }

    /// Un serveur muet doit donner une erreur lisible, pas un client lancé dans
    /// le vide.
    func testHandshakeFailsLoudlyWhenTheServerSaysNothing() throws {
        try ShellHarness.writeStub(named: "ssh", body: "echo 'bash: mosh-server: not found' >&2", in: directory)
        try ShellHarness.writeStub(named: "fake-client", body: "echo LANCÉ", in: directory)

        let command = try MoshDriver.handshakeCommand(
            for: shortcut(),
            clientPath: directory.appendingPathComponent("fake-client").path,
            address: "192.168.1.37"
        )
        let output = String(
            decoding: try ShellHarness.run(command, prependingToPath: directory), as: UTF8.self
        )
        XCTAssertFalse(output.contains("LANCÉ"), "le client ne doit pas être lancé")
    }

    /// Le chemin distant passe par le même échappement que le transport mosh :
    /// mosh-server exécute sans shell, donc `~/api` a besoin d'un `sh -c`.
    func testRemoteInvocationWrapsTildePathsInAShell() throws {
        let withTilde = try CommandBuilder.remoteInvocation(shortcut(directory: "~/api"))
        XCTAssertTrue(withTilde.hasPrefix("sh -c "), withTilde)

        let absolute = try CommandBuilder.remoteInvocation(shortcut(directory: "/srv/api"))
        XCTAssertEqual(absolute, "tmux new -A -s api -c /srv/api")
    }

    // MARK: Résolution

    /// `ssh -G` applique tout le ~/.ssh/config ; on ne réimplémente pas ce
    /// fichier. L'alias « billy » du §14 y est déclaré.
    func testResolvesAnAliasThroughSSHConfig() throws {
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.ssh/config") else {
            throw XCTSkip("pas de ~/.ssh/config sur cette machine")
        }
        let hostName = MoshDriver.sshHostName(for: "billy")
        XCTAssertNotNil(hostName)
        XCTAssertNotEqual(hostName, "", "ssh -G rend toujours une valeur")
    }

    func testResolvesNumericAddresses() {
        XCTAssertEqual(MoshDriver.numericAddress(of: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(MoshDriver.numericAddress(of: "192.168.1.37"), "192.168.1.37")
        XCTAssertNil(MoshDriver.numericAddress(of: "cet-hote-n-existe-pas.invalid"))
    }
}

// MARK: - Le Mac comme hôte

final class LocalToolsTests: XCTestCase {

    /// Le `PATH` n'est jamais consulté : celui d'une app lancée depuis le
    /// Finder ne contient ni /opt/homebrew/bin ni /usr/local/bin.
    func testSearchesAbsolutePathsOnly() {
        for path in LocalTools.searchPaths {
            XCTAssertTrue(path.hasPrefix("/"), path)
        }
        XCTAssertTrue(LocalTools.searchPaths.contains("/opt/homebrew/bin"))
        // L'installeur officiel de Claude Code pose son binaire là, et ce
        // dossier n'est jamais dans le PATH de launchd.
        XCTAssertEqual(LocalTools.searchPaths.first, NSHomeDirectory() + "/.local/bin")
    }

    /// Ce que launchd donne à une app sans réglage : c'est la référence pour
    /// savoir si un outil sera trouvable ou non.
    func testKnowsWhatLaunchdProvides() {
        XCTAssertEqual(LocalTools.launchdPaths, ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        XCTAssertFalse(LocalTools.launchdPaths.contains("/opt/homebrew/bin"))
    }

    func testFindsAToolThatExists() {
        XCTAssertEqual(LocalTools.path(of: "sh"), "/bin/sh")
        XCTAssertNil(LocalTools.path(of: "un-outil-qui-n-existe-pas"))
    }

    /// `/bin/sh` est dans le PATH de launchd, donc pas « hors PATH ».
    func testSystemToolsAreNotConsideredOffPath() {
        XCTAssertFalse(LocalTools.isOffPath("sh"))
        XCTAssertFalse(LocalTools.isOffPath("un-outil-qui-n-existe-pas"))
    }

    /// Une session locale n'ouvre aucune connexion : annoncer mosh manquant
    /// afficherait un bandeau pour rien.
    func testMoshIsIrrelevantLocally() {
        XCTAssertTrue(LocalTools.probe().hasMoshServer)
        XCTAssertEqual(LocalTools.probe().osID, "macos")
        // Et le diagnostic n'en parle pas : une ligne « mosh-server ✓ » sur une
        // session locale ne dit rien à personne.
        let plan = ServerUpgradePlanner.plan(for: LocalTools.probe(), wantsMosh: false)
        XCTAssertFalse(plan.diagnostics.contains { $0.name == "mosh-server" })
        XCTAssertTrue(plan.diagnostics.contains { $0.name == "claude" })
    }

    /// Claude Code est souvent installé sur le Mac aussi, dans `~/.local/bin`.
    /// Le déclarer absent parce qu'on ne l'y cherchait pas était un mensonge.
    func testTheLocalProbeLooksForClaude() {
        let probe = LocalTools.probe()
        XCTAssertEqual(probe.hasClaude, LocalTools.path(of: "claude") != nil)
        if let claude = LocalTools.path(of: "claude"), LocalTools.isOffPath("claude") {
            XCTAssertEqual(probe.offPathTools["claude"], claude)
        }
    }

    /// Et la sonde locale dit la vérité sur cette machine-ci, quelle qu'elle
    /// soit : tmux présent ou non, le résultat doit être cohérent.
    func testTheLocalProbeAgreesWithTheFilesystem() {
        let probe = LocalTools.probe()
        XCTAssertEqual(probe.hasTmux, LocalTools.path(of: "tmux") != nil)
        if let tmux = LocalTools.path(of: "tmux"), LocalTools.isOffPath("tmux") {
            XCTAssertEqual(probe.offPathTools["tmux"], tmux)
        }
    }

    /// Sans tmux, la session locale devient un shell et le dit — au lieu
    /// d'échouer sur « command not found ».
    func testDegradedLocalPlanCarriesAnExplanation() async throws {
        var local = shortcut(transport: .local, host: "", session: "notes")
        local.connection.workingDirectory = "~/Documents"

        let plan = try await LocalDriver().plan(for: local, degradation: .tmuxMissing)
        XCTAssertEqual(plan.command, "exec $SHELL")
        XCTAssertEqual(plan.notice?.contains("brew install tmux"), true)
    }

    /// Et avec tmux ailleurs que dans le PATH de launchd, il est appelé par son
    /// chemin absolu.
    func testTmuxOffPathIsCalledAbsolutely() async throws {
        let local = shortcut(transport: .local, host: "", session: "notes")
        let plan = try await LocalDriver().plan(
            for: local, degradation: .none, toolPaths: ["tmux": "/opt/homebrew/bin/tmux"]
        )
        XCTAssertEqual(plan.command, "/opt/homebrew/bin/tmux new -A -s notes")
    }
}

// MARK: - Sans ~/.ssh/config (§4 : « de préférence », pas « obligatoirement »)

final class SSHOptionsTests: XCTestCase {

    /// Le cas nominal : rien de renseigné, la commande reste celle du §5 et ssh
    /// essaie tout seul les clés par défaut du Mac.
    func testNothingSpecifiedChangesNothing() throws {
        XCTAssertTrue(SSHOptions.none.isEmpty)
        XCTAssertEqual(SSHOptions.none.arguments, [])
        XCTAssertNil(SSHOptions.none.moshArgument)

        var direct = shortcut(transport: .ssh, host: "billy@192.168.1.37")
        direct.connection.tmuxSession = "api"
        XCTAssertEqual(
            try CommandBuilder.build(direct),
            #"ssh -t billy@192.168.1.37 "tmux new -A -s api""#
        )
    }

    func testPortAndKeyReachTheCommandLine() throws {
        var custom = shortcut(transport: .ssh, host: "billy@192.168.1.37")
        custom.connection.port = 2222
        custom.connection.identityFile = "/Users/billy/.ssh/id_serveur"

        let command = try CommandBuilder.build(custom)
        XCTAssertTrue(command.hasPrefix("ssh -t -p 2222 -i /Users/billy/.ssh/id_serveur"), command)
        // Nommer une clé veut dire celle-là et pas une autre.
        XCTAssertTrue(command.contains("-o IdentitiesOnly=yes"), command)
    }

    /// Le tilde est développé ici : ssh l'accepte, mais la commande traverse un
    /// shell qui pourrait le laisser passer entre guillemets.
    func testTheKeyPathIsExpanded() {
        let options = SSHOptions(port: nil, identityFile: "~/.ssh/id_serveur")
        XCTAssertTrue(options.arguments.contains(NSHomeDirectory() + "/.ssh/id_serveur"))
    }

    /// mosh ne comprend ni `-p` ni `-i` : il les passe au ssh qu'il ouvre.
    func testMoshForwardsThemThroughItsOwnSSH() throws {
        var custom = shortcut(transport: .mosh, host: "billy@192.168.1.37", session: "dev")
        custom.connection.port = 2222

        let command = try CommandBuilder.build(custom)
        XCTAssertEqual(
            command,
            "mosh '--ssh=ssh -p 2222' billy@192.168.1.37 -- tmux new -A -s dev"
        )
    }

    /// Un port hors bornes est ignoré plutôt que d'être passé tel quel à ssh.
    func testAnImpossiblePortIsDropped() {
        XCTAssertNil(SSHOptions(port: 0).port)
        XCTAssertNil(SSHOptions(port: 99_999).port)
        XCTAssertEqual(SSHOptions(port: 2222).port, 2222)
    }

    func testBlankKeyIsTreatedAsAbsent() {
        XCTAssertTrue(SSHOptions(identityFile: "   ").isEmpty)
        XCTAssertTrue(SSHOptions(identityFile: "").isEmpty)
    }

    /// Le repli en shell nu garde le port et la clé : sans eux il ne joindrait
    /// pas l'hôte du tout.
    func testTheBareShellFallbackKeepsThem() {
        var connection = Connection(transport: .ssh, host: "billy", tmuxSession: "api")
        connection.port = 2222
        XCTAssertEqual(CommandBuilder.bareShellCommand(connection), "ssh -t -p 2222 billy")
    }
}
