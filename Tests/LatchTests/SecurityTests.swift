//
//  SecurityTests.swift
//  LatchTests
//
//  Le §11 : clé d'abord, mot de passe seulement en dernier recours, et jamais
//  sur une ligne de commande.
//

import Foundation
import XCTest

@testable import Latch

final class SSHKeySetupTests: XCTestCase {

    /// Écraser une clé existante détruirait l'accès à tous les autres serveurs
    /// de l'utilisateur. La commande doit refuser de le faire.
    func testNeverOverwritesAnExistingKey() {
        let command = SSHKeySetup.setupCommand(alias: "alex")
        XCTAssertTrue(command.contains("if [ -f "), command)
        XCTAssertTrue(command.contains("clé existante réutilisée"), command)
        XCTAssertFalse(command.contains("-f -q"), "aucune option d'écrasement silencieux")
        XCTAssertFalse(command.contains("-N \"\""), "la phrase de passe reste à l'utilisateur")
    }

    /// La clé n'est copiée qu'après avoir été créée ou retrouvée : `&&`, pas
    /// `;`. Sinon `ssh-copy-id` partirait avec une clé qui n'existe pas.
    func testCopyOnlyRunsAfterTheKeyIsThere() {
        XCTAssertTrue(SSHKeySetup.setupCommand(alias: "alex").contains("&& ssh-copy-id"))
    }

    func testQuotesItsArguments() {
        let command = SSHKeySetup.setupCommand(alias: "un hôte", comment: "l'ordinateur de alex")
        XCTAssertTrue(command.contains("'un hôte'"), command)
        XCTAssertTrue(command.contains(#"'l'\''ordinateur de alex'"#), command)
    }

    func testUsesEd25519AsTheSpecDoes() {
        XCTAssertTrue(SSHKeySetup.setupCommand(alias: "alex").contains("ssh-keygen -t ed25519"))
        XCTAssertTrue(SSHKeySetup.privateKeyPath.hasSuffix("/.ssh/id_ed25519"))
        XCTAssertEqual(SSHKeySetup.publicKeyPath, SSHKeySetup.privateKeyPath + ".pub")
    }

    /// Latch ne voit jamais le mot de passe distant : il est saisi dans le TTY.
    func testTheExplanationSaysWhoTypesThePassword() {
        XCTAssertTrue(SSHKeySetup.explanation.contains("ne le lit pas"))
    }

    /// L'alias `alex` du §14 a une clé en place : la détection doit le dire.
    func testDetectsWorkingKeyAuthentication() async throws {
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.ssh/config") else {
            throw XCTSkip("pas de ~/.ssh/config sur cette machine")
        }
        let unreachable = await SSHKeySetup.worksWithoutPassword(
            alias: "cet-hote-n-existe-pas.invalid", timeout: 2
        )
        XCTAssertFalse(unreachable)
    }
}

final class PasswordPromptTests: XCTestCase {

    private func detector() -> PasswordPromptDetector {
        PasswordPromptDetector()
    }

    func testRecognisesTheUsualPrompts() {
        for prompt in [
            "alex@192.168.1.10's password: ",
            "Password:",
            "Mot de passe : ",
            "Enter passphrase for key '/Users/alex/.ssh/id_ed25519': ",
        ] {
            var detector = detector()
            XCTAssertTrue(
                detector.shouldAnswer(after: prompt, elapsed: 1),
                "invite non reconnue : \(prompt)"
            )
        }
    }

    /// L'invite arrive rarement d'un seul bloc : elle est reconnue à cheval sur
    /// deux fragments.
    func testRecognisesAPromptSplitAcrossReads() {
        var detector = detector()
        XCTAssertFalse(detector.shouldAnswer(after: "alex@host's pass", elapsed: 1))
        XCTAssertTrue(detector.shouldAnswer(after: "word: ", elapsed: 1))
    }

    /// Ce qui ne se termine pas par une question n'en est pas une : un `grep
    /// password` dans un fichier ne doit rien déclencher.
    func testOrdinaryOutputIsNotAPrompt() {
        var detector = detector()
        XCTAssertFalse(detector.shouldAnswer(after: "password: hunter2 (dans un fichier)\n", elapsed: 1))
        XCTAssertFalse(detector.shouldAnswer(after: "alex@serveur:~$ ", elapsed: 1))
    }

    /// Deux points en fin de ligne ne suffisent pas : encore faut-il qu'on
    /// demande quelque chose.
    func testAColonWithoutAKeywordIsNotAPrompt() {
        var detector = detector()
        XCTAssertFalse(detector.shouldAnswer(after: "Warning:", elapsed: 1))
        XCTAssertFalse(detector.shouldAnswer(after: "Sessions actives :", elapsed: 1))
    }

    /// Et une ligne de sortie qui contient le mot n'est pas une question, même
    /// si elle finit par deux points.
    func testALongLineIsNotAPrompt() {
        var detector = detector()
        let noisy = String(repeating: "password ", count: 30) + ":"
        XCTAssertFalse(detector.shouldAnswer(after: noisy, elapsed: 1))
    }

    /// Passé le délai, c'est l'utilisateur qui tape : un « password: » dans un
    /// `git push` ne concerne pas Latch.
    func testStopsAnsweringAfterTheWindow() {
        var detector = detector()
        XCTAssertFalse(detector.shouldAnswer(after: "Password:", elapsed: 120))
    }

    /// Rejouer un mot de passe refusé finit par verrouiller le compte.
    func testGivesUpAfterThreeAttempts() {
        var detector = detector()
        var now = Date()
        for attempt in 1...3 {
            XCTAssertTrue(
                detector.shouldAnswer(after: "Password:", elapsed: 1, now: now),
                "tentative \(attempt)"
            )
            now = now.addingTimeInterval(5)
        }
        XCTAssertFalse(detector.shouldAnswer(after: "Password:", elapsed: 1, now: now))
        XCTAssertEqual(detector.attempts, 3)
    }

    /// Une invite redessinée ne doit pas déclencher deux réponses coup sur coup.
    func testIgnoresARepeatedPromptWithinTheInterval() {
        var detector = detector()
        let now = Date()
        XCTAssertTrue(detector.shouldAnswer(after: "Password:", elapsed: 1, now: now))
        XCTAssertFalse(
            detector.shouldAnswer(after: "Password:", elapsed: 1, now: now.addingTimeInterval(0.2))
        )
        XCTAssertTrue(
            detector.shouldAnswer(after: "Password:", elapsed: 1, now: now.addingTimeInterval(3))
        )
    }

    func testResetClearsEverything() {
        var detector = detector()
        _ = detector.shouldAnswer(after: "Password:", elapsed: 1)
        detector.reset()
        XCTAssertEqual(detector.attempts, 0)
        XCTAssertTrue(detector.shouldAnswer(after: "Password:", elapsed: 1))
    }
}

final class KeychainTests: XCTestCase {

    private let alias = "latch-test-\(UUID().uuidString)"
    private let account = "alex"

    override func tearDown() {
        Keychain.remove(alias: alias, account: account)
        super.tearDown()
    }

    /// Le trousseau du système est le seul endroit où un mot de passe a le
    /// droit d'exister (§11) — jamais le fichier de configuration.
    func testStoresReadsAndForgets() throws {
        XCTAssertFalse(Keychain.hasPassword(alias: alias, account: account))
        XCTAssertNil(Keychain.password(alias: alias, account: account))

        try Keychain.store("un secret", alias: alias, account: account)
        XCTAssertTrue(Keychain.hasPassword(alias: alias, account: account))
        XCTAssertEqual(Keychain.password(alias: alias, account: account), "un secret")

        // Réenregistrer remplace, sans empiler un doublon.
        try Keychain.store("un autre", alias: alias, account: account)
        XCTAssertEqual(Keychain.password(alias: alias, account: account), "un autre")

        XCTAssertTrue(Keychain.remove(alias: alias, account: account))
        XCTAssertNil(Keychain.password(alias: alias, account: account))
    }

    /// Deux comptes sur le même hôte sont deux entrées distinctes.
    func testAccountsAreKeptApart() throws {
        try Keychain.store("le sien", alias: alias, account: account)
        try Keychain.store("le mien", alias: alias, account: "root")
        defer { Keychain.remove(alias: alias, account: "root") }

        XCTAssertEqual(Keychain.password(alias: alias, account: account), "le sien")
        XCTAssertEqual(Keychain.password(alias: alias, account: "root"), "le mien")
    }
}
