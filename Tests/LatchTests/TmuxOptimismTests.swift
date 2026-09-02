//
//  TmuxOptimismTests.swift
//  LatchTests
//
//  La barre latérale décide seule de ce qu'elle affiche entre deux tours de
//  boucle. Elle a donc le droit de se tromper — mais jamais de fabriquer une
//  fenêtre, d'en perdre une, ou d'en montrer deux actives à la fois.
//

import XCTest

@testable import Latch

final class TmuxOptimismTests: XCTestCase {

    private func windows(active: Int) -> [LiveWindow] {
        [0, 1, 2].map {
            LiveWindow(
                session: "api", index: $0, name: "w\($0)",
                isActive: $0 == active, currentCommand: "bash"
            )
        }
    }

    // MARK: - Sélection

    func testSelectingMovesTheActiveMarkAndMovesItOnlyOnce() {
        let result = TmuxOptimism.selecting(index: 2, in: windows(active: 0))

        XCTAssertEqual(result.filter(\.isActive).map(\.index), [2])
        XCTAssertEqual(result.count, 3, "aucune fenêtre ne doit apparaître ni disparaître")
        XCTAssertEqual(result.map(\.index), [0, 1, 2], "l'ordre est celui de tmux")
    }

    func testSelectingTheAlreadyActiveWindowChangesNothing() {
        let before = windows(active: 1)
        XCTAssertEqual(TmuxOptimism.selecting(index: 1, in: before), before)
    }

    /// Une fenêtre fermée entre-temps : on ne l'invente pas, et on ne laisse
    /// pas la session sans fenêtre active.
    func testSelectingAnUnknownIndexLeavesTheListAlone() {
        let before = windows(active: 0)
        XCTAssertEqual(TmuxOptimism.selecting(index: 9, in: before), before)
    }

    func testSelectingInAnEmptyListIsHarmless() {
        XCTAssertEqual(TmuxOptimism.selecting(index: 0, in: []), [])
    }

    // MARK: - Renommage

    func testRenamingTouchesOneWindow() {
        let result = TmuxOptimism.renaming(id: "api:1", to: "journaux", in: windows(active: 0))

        XCTAssertEqual(result.map(\.name), ["w0", "journaux", "w2"])
        XCTAssertEqual(result.filter(\.isActive).map(\.index), [0], "renommer ne sélectionne pas")
    }

    /// tmux refuse un nom vide : la barre latérale ne doit pas afficher ce que
    /// le serveur va rejeter.
    func testRenamingToNothingIsRefused() {
        let before = windows(active: 0)
        XCTAssertEqual(TmuxOptimism.renaming(id: "api:1", to: "   ", in: before), before)
    }

    func testRenamingTrimsTheName() {
        let result = TmuxOptimism.renaming(id: "api:1", to: "  api  ", in: windows(active: 0))
        XCTAssertEqual(result[1].name, "api")
    }

    func testRenamingAnUnknownWindowChangesNothing() {
        let before = windows(active: 0)
        XCTAssertEqual(TmuxOptimism.renaming(id: "api:9", to: "x", in: before), before)
    }

    // MARK: - Fermeture

    func testRemovingDropsOnlyThatWindow() {
        let result = TmuxOptimism.removing(id: "api:1", from: windows(active: 0))
        XCTAssertEqual(result.map(\.index), [0, 2])
    }

    func testRemovingAnUnknownWindowChangesNothing() {
        let before = windows(active: 0)
        XCTAssertEqual(TmuxOptimism.removing(id: "api:9", from: before), before)
    }

    /// Fermer la fenêtre active laisse la liste sans marque : c'est tmux qui
    /// décide où la sélection atterrit, et le tour suivant le dira.
    func testRemovingTheActiveWindowDoesNotGuessTheNextOne() {
        let result = TmuxOptimism.removing(id: "api:0", from: windows(active: 0))
        XCTAssertTrue(result.allSatisfy { !$0.isActive })
    }
}
