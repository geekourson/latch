//
//  LegendTests.swift
//  LatchTests
//
//  Une légende se périme au premier état ajouté. Ces tests la relient aux
//  couleurs réellement affichées : ajouter une pastille sans l'expliquer fait
//  tomber la suite.
//

import SwiftUI
import XCTest

@testable import Latch

@MainActor
final class LegendTests: XCTestCase {

    private let states: [ConnectionState] = [
        .idle, .connecting, .connected, .reconnecting(attempt: 1),
        .degraded(reason: "sans mosh"), .failed(reason: "injoignable"),
    ]

    func testEveryConnectionStateUsesAnExplainedColor() {
        for state in states {
            XCTAssertTrue(
                LegendView.explainedColors.contains(state.dotColor),
                "l'état « \(state.label) » emploie une couleur que la légende n'explique pas"
            )
        }
    }

    func testEveryClaudeStateUsesAnExplainedColor() {
        for attention: ClaudeAttention? in [nil, .reply, .permission] {
            var activity = ClaudeActivity()
            activity.attention = attention
            XCTAssertTrue(
                LegendView.explainedColors.contains(ClaudeDot.color(for: activity)),
                "l'attente \(String(describing: attention)) n'est pas expliquée"
            )
        }
    }

    /// Le violet est celui de Claude Code, et rien d'autre : c'est ce qui
    /// permet de le repérer du coin de l'œil.
    func testOnlyClaudeWearsViolet() {
        for state in states {
            XCTAssertNotEqual(state.dotColor, .latchClaude, "« \(state.label) » porte le violet")
        }

        var working = ClaudeActivity()
        working.attention = nil
        XCTAssertEqual(ClaudeDot.color(for: working), .latchClaude)
    }

    /// Ce qui t'attend porte la même couleur, qu'il s'agisse d'une connexion
    /// morte ou de Claude bloqué : c'est la même demande.
    func testWhatWaitsOnYouSharesOneColor() {
        var blocked = ClaudeActivity()
        blocked.attention = .permission
        XCTAssertEqual(ClaudeDot.color(for: blocked), .latchAttention)
        XCTAssertEqual(ConnectionState.failed(reason: "x").dotColor, .latchAttention)
    }

    /// Une connexion en cours n'attend rien de toi : elle ne doit pas porter
    /// une couleur qui appelle.
    func testProgressIsNotAnAlarm() {
        for state in [ConnectionState.connecting, .reconnecting(attempt: 3)] {
            XCTAssertEqual(state.dotColor, .latchPending)
        }
    }

    /// Les six couleurs sont distinctes : deux teintes identiques rendraient
    /// la légende plus longue que lisible.
    func testTheSixColorsAreDistinct() {
        XCTAssertEqual(LegendView.explainedColors.count, 6)
    }

    /// La légende est traduite comme le reste : elle explique l'interface, et
    /// une explication en français dans une interface en anglais n'explique
    /// plus rien.
    func testTheLegendIsTranslated() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        let missing = "⟨absente⟩"

        for key in ["Repères", "Connecté", "En cours", "Dégradé", "Bloqué", "À toi", "Inactif",
                    "Rien ne tourne, et rien n'attend."] {
            XCTAssertNotEqual(
                english.localizedString(forKey: key, value: missing, table: nil), missing,
                "« \(key) » n'est pas traduit"
            )
        }
    }
}
