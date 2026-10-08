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

    /// La souris de tmux est activée pour la molette ; le clic gauche, lui,
    /// reste au terminal pendant tout le geste, puis la molette retrouve tmux.
    func testALeftClickSelectsLocallyThenTheWheelGoesBackToTmux() throws {
        let pane = PaddedTerminalView(inset: 0)
        pane.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        pane.layout()
        let terminal = pane.terminalView

        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        XCTAssertTrue(terminal.allowMouseReporting)
        terminal.mouseDown(with: try event(.leftMouseDown))
        XCTAssertFalse(terminal.allowMouseReporting, "tmux ne doit pas voler la sélection")
        terminal.mouseUp(with: try event(.leftMouseUp))
        XCTAssertTrue(terminal.allowMouseReporting, "la molette doit revenir à tmux")
    }
}
