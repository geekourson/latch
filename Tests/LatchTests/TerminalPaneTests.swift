//
//  TerminalPaneTests.swift
//  LatchTests
//
//  La fenêtre se déplace par son fond. Le terminal n'en fait pas partie :
//  sans ça, sélectionner du texte emporte la fenêtre.
//

import AppKit
import XCTest

@testable import Latch

@MainActor
final class TerminalPaneTests: XCTestCase {

    func testDraggingInTheTerminalSelectsInsteadOfMovingTheWindow() {
        let pane = PaddedTerminalView(inset: 20)
        XCTAssertFalse(pane.terminalView.mouseDownCanMoveWindow)
        XCTAssertFalse(pane.mouseDownCanMoveWindow, "la marge fait partie du terminal")
    }
}
