//
//  ShellQuotingTests.swift
//  LatchTests
//
//  L'échappement est « le point le plus fragile du projet » (SPEC §5). On ne le
//  teste donc pas contre des chaînes écrites à la main — elles seraient fausses
//  aussi souvent que le code —, mais contre un vrai `/bin/sh`, en vérifiant que
//  ce qui ressort de l'autre côté est exactement ce qu'on avait mis dedans.
//

import Foundation
import XCTest

@testable import Latch

final class ShellQuotingTests: XCTestCase {

    /// Les chaînes que le §5 demande explicitement de couvrir, et quelques
    /// autres qui font tomber une implémentation approximative.
    private static let nastyStrings = [
        "simple",
        "avec des espaces",
        "l'apostrophe",
        "trois''apostrophes'",
        #"des "guillemets" doubles"#,
        "un $DOLLAR et un ${BRACE}",
        "des `backticks`",
        #"une \barre oblique inverse"#,
        "point-virgule; et && un pipe |",
        "> redirection < et 2>&1",
        "un * joker et un ? point d'interrogation",
        "retour\nà la ligne",
        "tabulation\tinterne",
        "accents éàü et emoji 🔒",
        "~/tilde/au/milieu",
        "!histoire",
        "(sous-shell)",
        "",
    ]

    // MARK: - Guillemets simples

    func testSingleQuotingSurvivesARealShell() throws {
        for original in Self.nastyStrings {
            let quoted = ShellQuoting.singleQuoted(original)
            let roundTripped = try firstArgument(passing: quoted)
            XCTAssertEqual(roundTripped, original, "chaîne : \(original.debugDescription)")
        }
    }

    func testConditionalQuotingSurvivesARealShell() throws {
        for original in Self.nastyStrings where !original.isEmpty {
            let quoted = ShellQuoting.quoted(original)
            let roundTripped = try firstArgument(passing: quoted)
            XCTAssertEqual(roundTripped, original, "chaîne : \(original.debugDescription)")
        }
    }

    func testUnremarkableStringsAreLeftAlone() {
        XCTAssertEqual(ShellQuoting.quoted("api"), "api")
        XCTAssertEqual(ShellQuoting.quoted("alex@192.168.1.10"), "alex@192.168.1.10")
        XCTAssertEqual(ShellQuoting.quoted("/srv/api"), "/srv/api")
        XCTAssertEqual(ShellQuoting.quoted("--model=opus"), "--model=opus")
    }

    func testEmptyStringIsQuoted() {
        XCTAssertEqual(ShellQuoting.quoted(""), "''")
    }

    // MARK: - Guillemets doubles

    /// Entre guillemets doubles, le `$` doit rester littéral pour le shell
    /// local : c'est ce qui permet à `$SHELL` d'arriver intact chez le shell
    /// distant, qui est le seul à savoir ce qu'il vaut.
    func testDoubleQuotingSurvivesARealShell() throws {
        for original in Self.nastyStrings {
            let quoted = ShellQuoting.doubleQuoted(original)
            let roundTripped = try firstArgument(passing: quoted)
            XCTAssertEqual(roundTripped, original, "chaîne : \(original.debugDescription)")
        }
    }

    func testDollarIsNeutralisedForTheLocalShell() {
        XCTAssertEqual(ShellQuoting.doubleQuoted("exec $SHELL"), #""exec \$SHELL""#)
    }

    // MARK: - Chemins distants

    /// tmux n'étend pas le tilde : `tmux new -c "~/api"` atterrit dans le
    /// répertoire personnel. Il faut donc qu'un shell le voie nu.
    func testTildeStaysOutsideTheQuotes() {
        XCTAssertEqual(ShellQuoting.remotePath("~"), "~")
        XCTAssertEqual(ShellQuoting.remotePath("~/api"), "~/api")
        XCTAssertEqual(ShellQuoting.remotePath("~/mes projets"), "~/'mes projets'")
        XCTAssertEqual(ShellQuoting.remotePath("~alex/api"), "~alex/api")
    }

    func testAbsolutePathsAreQuotedNormally() {
        XCTAssertEqual(ShellQuoting.remotePath("/srv/api"), "/srv/api")
        XCTAssertEqual(ShellQuoting.remotePath("/srv/mon api"), "'/srv/mon api'")
    }

    /// Un chemin avec tilde, une fois développé par un vrai shell, doit
    /// désigner le bon répertoire — espaces compris.
    func testTildePathExpandsToTheHomeDirectory() throws {
        let expanded = try firstArgument(passing: ShellQuoting.remotePath("~/mes projets"))
        XCTAssertEqual(expanded, NSHomeDirectory() + "/mes projets")
    }

    func testShellExpansionIsDetected() {
        XCTAssertTrue(ShellQuoting.needsShellExpansion("~/api"))
        XCTAssertTrue(ShellQuoting.needsShellExpansion("$HOME/api"))
        XCTAssertFalse(ShellQuoting.needsShellExpansion("/srv/api"))
        XCTAssertFalse(ShellQuoting.needsShellExpansion("relatif/api"))
    }

    // MARK: - Outillage

    /// Fait passer un fragment déjà cité par `/bin/sh` et rend le premier
    /// argument tel que le programme appelé le reçoit vraiment.
    private func firstArgument(passing fragment: String) throws -> String {
        let arguments = try ShellHarness.arguments(of: "argv " + fragment)
        return arguments.first ?? ""
    }
}
