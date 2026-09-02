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
