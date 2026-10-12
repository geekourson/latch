//
//  TerminalPaneTests.swift
//  LatchTests
//
//  La fenêtre se déplace par son fond. Le terminal n'en fait pas partie :
//  sans ça, sélectionner du texte emporte la fenêtre.
//

import AppKit
import SwiftTerm
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

    /// ⌘⌫ efface la ligne comme dans Terminal : le shell reçoit ^U.
    func testCommandDeleteErasesTheLine() throws {
        let pane = PaddedTerminalView(inset: 0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = pane
        let terminal = pane.terminalView
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let spy = SentBytes()
        terminal.terminalDelegate = spy

        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false, keyCode: 51
            ))
        }

        XCTAssertTrue(terminal.performKeyEquivalent(with: try key(.command)))
        XCTAssertEqual(spy.bytes, [0x15])
        XCTAssertFalse(terminal.performKeyEquivalent(with: try key([.command, .option])))
        XCTAssertEqual(spy.bytes, [0x15], "⌘⌥⌫ n'est pas concerné")
    }
}

private final class SentBytes: TerminalViewDelegate {
    var bytes: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
