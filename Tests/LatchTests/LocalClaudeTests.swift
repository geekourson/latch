//
//  LocalClaudeTests.swift
//  LatchTests
//
//  Claude Code tourne aussi bien sur le Mac que sur un serveur, et Latch était
//  aveugle au premier cas : le flux de hooks était coupé net pour un hôte
//  local, et le panneau ne proposait ni l'installation ni le MCP.
//
//  Ce qui rend le local possible tient en une phrase : rien dans le §10 n'est
//  propre à ssh. Le hook écrit un fichier, le suivi lit un fichier, et
//  l'installation n'écrit que dans le dossier personnel. Ces tests gardent
//  cette propriété, qui est fragile — il suffit d'un `ssh` glissé dans une
//  commande partagée pour la perdre.
//

import XCTest

@testable import Latch

@MainActor
final class LocalClaudeTests: XCTestCase {

    // MARK: - Qui est local

    func testAnEmptyAliasMeansThisMac() {
        XCTAssertTrue(HookStream(alias: "").isLocal)
        XCTAssertFalse(HookStream(alias: "serveur").isLocal)
    }

    /// Le Mac n'a pas d'alias : c'est ce qui le distingue d'un hôte à joindre,
    /// partout dans le code.
    func testTheMacHasNoAliasToReach() {
        XCTAssertNil(UpgradeTarget.localMac.alias)
        XCTAssertTrue(UpgradeTarget.localMac.isLocal)
    }

    // MARK: - Les commandes ne supposent pas de connexion

    /// Le cœur de l'affaire : la commande de suivi est du shell ordinaire. Si
    /// quelqu'un y glisse un `ssh`, le local cesse de fonctionner en silence.
    func testTheFollowCommandIsPlainShell() {
        let command = HookInstaller.followCommand
        XCTAssertFalse(command.contains("ssh"), "le suivi ne doit rien supposer d'une connexion")
        XCTAssertTrue(command.contains("tail"))
        XCTAssertTrue(command.contains("$HOME") || command.contains("~"))
    }

    func testTheInstallCommandIsPlainShell() {
        let command = HookInstaller.installCommand
        XCTAssertFalse(command.contains("ssh"))
        // Elle n'écrit que dans le dossier personnel : c'est ce qui permet de
        // l'exécuter sans sudo, ici comme là-bas.
        XCTAssertFalse(command.contains("sudo"), "aucune élévation, des deux côtés")
        XCTAssertTrue(command.contains("~/.latch"))
    }

    /// Elle tourne vraiment sous `/bin/sh` : la vérifier par lecture ne suffit
    /// pas, une expansion ratée ne se voit qu'à l'exécution.
    func testTheFollowCommandRunsUnderBinSh() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // On ne lance pas le `tail` de la vraie commande — il ne rendrait
        // jamais la main. On vérifie la partie qui prépare le terrain.
        let preparation = HookInstaller.followCommand
            .components(separatedBy: "tail")[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: " &"))
        process.arguments = ["-c", preparation]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "« \(preparation) » doit passer sous /bin/sh")
    }

    // MARK: - Le rattachement à une session

    /// Les hooks ne connaissent qu'un `cwd`, et l'inspecteur local relève le
    /// répertoire de chaque panneau exactement comme le distant : le témoin se
    /// pose donc sur la bonne session locale sans rien de particulier.
    func testALocalHookEventCarriesWhatLinksItToASession() throws {
        let line = #"""
            {"hook_event_name":"Notification","notification_type":"permission_prompt",\#
            "message":"Claude needs your permission","cwd":"/Users/alex/atelier"}
            """#
        let event = try XCTUnwrap(HookEvent.parse(line: line))
        XCTAssertEqual(event.attention, .permission)
        XCTAssertEqual(event.cwd, "/Users/alex/atelier")

        var activity = ClaudeActivity()
        activity.apply(event)
        XCTAssertEqual(activity.directory, "/Users/alex/atelier")
    }

    /// La boucle d'inspection locale émet le répertoire comme la distante :
    /// c'est la même commande, montée sans ssh.
    func testTheLocalWatchCommandAlsoEmitsDirectories() {
        let command = TmuxInspector.watchCommand(tmux: "/opt/homebrew/bin/tmux")
        XCTAssertTrue(command.contains(TmuxInspector.pathPrefix))
        XCTAssertTrue(command.contains("/opt/homebrew/bin/tmux"))
    }

    // MARK: - Le MCP

    /// En local, il n'y a pas de tunnel à porter : le serveur est déjà à
    /// l'adresse que la commande d'enregistrement annonce.
    func testTheRegistrationCommandNeedsNoTunnelLocally() async {
        let server = MCPServer(port: 0)
        await server.start()
        defer { Task { await server.stop() } }

        let command = server.claudeRegistrationCommand
        XCTAssertTrue(command.contains("127.0.0.1"), "l'adresse vaut des deux côtés")
        XCTAssertTrue(command.contains("Authorization: Bearer"))
        XCTAssertFalse(command.contains("-R"), "le tunnel n'est pas dans la commande")
    }
}
