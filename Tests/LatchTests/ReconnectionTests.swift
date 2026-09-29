//
//  ReconnectionTests.swift
//  LatchTests
//
//  Le cycle de vie du §8 : veille, réveil, backoff plafonné, et l'arrêt après
//  trois échecs plutôt qu'une boucle silencieuse.
//

import XCTest

@testable import Latch

final class ReconnectionPolicyTests: XCTestCase {

    private let policy = ReconnectionPolicy()

    func testBackoffDoublesUntilTheCap() {
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 8)
        XCTAssertEqual(policy.delay(forAttempt: 5), 16)
    }

    /// Plafonné à 30 s, quoi qu'il arrive au compteur.
    func testBackoffIsCappedAtThirtySeconds() {
        XCTAssertEqual(policy.delay(forAttempt: 6), 30)
        XCTAssertEqual(policy.delay(forAttempt: 40), 30)
        XCTAssertEqual(policy.delay(forAttempt: 10_000), 30)
    }

    func testNoDelayBeforeTheFirstAttempt() {
        XCTAssertEqual(policy.delay(forAttempt: 0), 0)
    }

    /// « Après 3 échecs, passer en .failed et attendre une action. »
    func testGivesUpAfterThreeAttempts() {
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 1))
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 2))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 3))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 4))
    }

    /// Une connexion qui meurt aussitôt n'a jamais abouti ; une qui a vécu une
    /// heure a simplement été quittée.
    func testShortLivedConnectionsCountAsFailures() {
        XCTAssertTrue(policy.countsAsFailure(lifetime: 0.2))
        XCTAssertTrue(policy.countsAsFailure(lifetime: 4.9))
        XCTAssertFalse(policy.countsAsFailure(lifetime: 5.1))
        XCTAssertFalse(policy.countsAsFailure(lifetime: 3600))
    }

    /// Le code 255 de ssh mérite d'être nommé : c'est le plus fréquent, et le
    /// plus opaque.
    func testGiveUpReasonNamesTheSSHExitCode() {
        XCTAssertTrue(policy.giveUpReason(lastExitCode: 255).contains("255"))
        XCTAssertFalse(policy.giveUpReason(lastExitCode: 1).contains("255"))
    }
}

@MainActor
final class TerminalSessionLifecycleTests: XCTestCase {

    /// Attend que `condition` soit vraie, sans bloquer l'acteur principal.
    private func wait(
        upTo seconds: TimeInterval = 5,
        for condition: @MainActor () -> Bool,
        _ message: String
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("délai dépassé : \(message)")
    }

    private func makeSession(command: String) -> TerminalSession {
        let session = TerminalSession(name: "test", command: command, host: "alex")
        // Backoff raccourci : on teste la logique, pas la patience.
        session.policy = ReconnectionPolicy(
            base: 0.05, cap: 0.1, maxAttempts: 3, minimumLifetime: 5
        )
        return session
    }

    func testStartingReachesTheConnectedState() async {
        let session = makeSession(command: "sleep 30")
        session.start(rows: 24, cols: 80)
        await wait(for: { session.connection == .connected }, "la session se connecte")
        session.terminate()
    }

    /// « didSleepNotification → marquer les sessions .reconnecting, ne rien
    /// tuer. »
    func testSleepMarksWithoutKilling() async {
        let session = makeSession(command: "sleep 30")
        session.start(rows: 24, cols: 80)
        await wait(for: { session.connection == .connected }, "la session se connecte")

        session.systemWillSleep()
        XCTAssertEqual(session.connection, .reconnecting(attempt: 0))

        // Le process est toujours là : rien n'a été tué.
        session.systemDidWake()
        XCTAssertEqual(session.connection, .connected)
        session.terminate()
    }

    /// Au réveil, un process vivant — le cas normal avec mosh — ne déclenche
    /// aucune relance.
    func testWakingALiveSessionChangesNothing() async {
        let session = makeSession(command: "sleep 30")
        session.start(rows: 24, cols: 80)
        await wait(for: { session.connection == .connected }, "la session se connecte")

        session.systemWillSleep()
        session.systemDidWake()
        await wait(for: { session.connection == .connected }, "la session reste connectée")
        XCTAssertNil(session.lastExitCode, "aucun process n'est mort")
        session.terminate()
    }

    /// Un process mort pendant la veille est relancé au réveil, avec exactement
    /// la même commande.
    func testWakingADeadSessionRelaunchesIt() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        // La commande est identique aux deux lancements — c'est justement ce
        // que le §8 exige. Elle compte ses propres passages : elle sort tout de
        // suite la première fois, et tient la seconde.
        let path = marker.path
        let session = makeSession(
            command: "echo x >> \(path); "
                + "if [ \"$(wc -l < \(path))\" -ge 2 ]; then sleep 30; else exit 0; fi"
        )
        session.start(rows: 24, cols: 80)
        await wait(for: { session.lastExitCode != nil }, "le process meurt")

        // Le Mac s'endort avec un process déjà mort, puis se réveille.
        session.systemWillSleep()
        session.systemDidWake()
        await wait(for: { session.connection == .connected }, "la session se relance")

        let runs = (try? String(contentsOf: marker, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        XCTAssertEqual(runs, 2, "la même commande a été relancée une fois")
        session.terminate()
    }

    /// Une commande qui échoue aussitôt n'est pas retentée indéfiniment : trois
    /// tentatives, puis on s'arrête et on attend une action.
    func testGivesUpAfterThreeFailedAttempts() async {
        let session = makeSession(command: "exit 255")
        session.start(rows: 24, cols: 80)
        await wait(for: { session.lastExitCode == 255 }, "premier échec")

        session.systemWillSleep()
        session.systemDidWake()

        await wait(upTo: 8, for: {
            if case .failed = session.connection { return true }
            return false
        }, "la session abandonne")

        guard case .failed(let reason) = session.connection else {
            return XCTFail("état inattendu : \(session.connection)")
        }
        XCTAssertTrue(reason.contains("255"), reason)

        // Et elle reste abandonnée : un réveil de plus ne relance pas la boucle.
        session.systemDidWake()
        if case .failed = session.connection {} else {
            XCTFail("un réveil a rouvert la boucle : \(session.connection)")
        }
        session.terminate()
    }

    /// Fermer l'onglet annule la reconnexion en cours (§8).
    func testClosingCancelsAPendingReconnection() async {
        let session = makeSession(command: "exit 1")
        session.start(rows: 24, cols: 80)
        await wait(for: { session.lastExitCode == 1 }, "premier échec")

        session.systemWillSleep()
        session.systemDidWake()
        session.terminate()

        let stateAtClose = session.connection
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(session.connection, stateAtClose, "plus rien ne bouge après la fermeture")
    }
}
