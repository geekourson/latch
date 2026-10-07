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

    // MARK: - La fenêtre voisine

    /// ⇧⌘] et ⇧⌘[ bouclent : depuis la dernière on revient à la première, et
    /// inversement. Le modulo de Swift garde le signe du dividende, donc
    /// reculer depuis la première est le cas qui casse si on l'oublie.
    func testTheNeighbourWrapsAtBothEnds() {
        XCTAssertEqual(TmuxOptimism.neighbour(in: windows(active: 0), offset: 1)?.index, 1)
        XCTAssertEqual(TmuxOptimism.neighbour(in: windows(active: 2), offset: 1)?.index, 0)
        XCTAssertEqual(TmuxOptimism.neighbour(in: windows(active: 0), offset: -1)?.index, 2)
        XCTAssertEqual(TmuxOptimism.neighbour(in: windows(active: 1), offset: -1)?.index, 0)
    }

    /// Une session d'une seule fenêtre n'a pas de voisine : il ne faut pas
    /// renvoyer l'active, ce qui enverrait un `select-window` pour rien.
    func testASingleWindowHasNoNeighbour() {
        let alone = [LiveWindow(session: "api", index: 0, name: "w", isActive: true)]
        XCTAssertNil(TmuxOptimism.neighbour(in: alone, offset: 1))
        XCTAssertNil(TmuxOptimism.neighbour(in: [], offset: 1))
    }

    /// Sans fenêtre active — un lot arrivé entre deux tours — on ne devine pas.
    func testWithoutAnActiveWindowThereIsNothingToLeaveFrom() {
        let none = [0, 1].map {
            LiveWindow(session: "api", index: $0, name: "w\($0)", isActive: false)
        }
        XCTAssertNil(TmuxOptimism.neighbour(in: none, offset: 1))
    }

    func testAZeroOffsetMovesNothing() {
        XCTAssertNil(TmuxOptimism.neighbour(in: windows(active: 1), offset: 0))
    }

    /// Un saut plus grand que la liste reste dans la liste.
    func testALargeOffsetStaysInRange() {
        XCTAssertEqual(TmuxOptimism.neighbour(in: windows(active: 0), offset: 4)?.index, 1)
        XCTAssertEqual(TmuxOptimism.neighbour(in: windows(active: 0), offset: -4)?.index, 2)
    }

    // MARK: - Un shell nu

    /// Ce qui distingue une fenêtre qu'on ferme sans demander de celle où
    /// quelque chose tourne.
    func testAnIdleShellIsRecognised() {
        for shell in ["bash", "zsh", "sh", "fish", "-bash", "-zsh"] {
            let window = LiveWindow(
                session: "api", index: 0, name: "w", isActive: true, currentCommand: shell
            )
            XCTAssertTrue(window.isIdleShell, shell)
        }
    }

    func testSomethingRunningIsNotAnIdleShell() {
        for command in ["claude", "vim", "journalctl", "node", "bash -c make"] {
            let window = LiveWindow(
                session: "api", index: 0, name: "w", isActive: true, currentCommand: command
            )
            XCTAssertFalse(window.isIdleShell, command)
        }
    }

    /// Une fenêtre dont on ne sait rien n'est pas réputée vide : on confirme
    /// plutôt que de fermer ce qu'on n'a pas vu.
    func testAnUnknownCommandIsNotTreatedAsIdle() {
        let window = LiveWindow(session: "api", index: 0, name: "w", isActive: true)
        XCTAssertFalse(window.isIdleShell)
    }
}
