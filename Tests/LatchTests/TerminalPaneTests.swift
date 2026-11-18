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

    /// Ce que le terminal envoie à l'application : ici, à tmux.
    private final class Recorder: NSObject, TerminalViewDelegate {
        var sent = Data()
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, x: CGFloat = 10, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 10), modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    /// Un terminal où tmux a demandé la souris, comme avec `mouse on`.
    private func terminalUnderTmux() -> (TerminalView, Recorder) {
        let pane = PaddedTerminalView(inset: 0)
        pane.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        pane.layout()
        let terminal = pane.terminalView
        let recorder = Recorder()
        terminal.terminalDelegate = recorder
        terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        return (terminal, recorder)
    }

    /// Le glisser va à tmux : seule sa sélection descend dans l'historique.
    func testADragGoesToTmuxSoItCanScrollThroughTheHistory() throws {
        let (terminal, recorder) = terminalUnderTmux()

        terminal.mouseDown(with: try mouseEvent(.leftMouseDown))
        terminal.mouseDragged(with: try mouseEvent(.leftMouseDragged, x: 80))
        terminal.mouseUp(with: try mouseEvent(.leftMouseUp, x: 80))

        XCTAssertTrue(String(decoding: recorder.sent, as: UTF8.self).contains("\u{1b}[<"),
                      "tmux doit recevoir l'appui, le glisser et le relâchement")
        XCTAssertFalse(terminal.selectionActive)
        XCTAssertTrue(terminal.allowMouseReporting)
    }

    /// ⌥ garde la sélection au terminal, sans rien envoyer à tmux ; la souris
    /// lui revient quand la sélection tombe.
    func testOptionDragSelectsLocally() throws {
        let (terminal, recorder) = terminalUnderTmux()
        terminal.feed(text: "à copier\r\n")

        terminal.mouseDown(with: try mouseEvent(.leftMouseDown, modifiers: .option))
        XCTAssertFalse(terminal.allowMouseReporting, "tmux ne doit pas voler la sélection")
        terminal.mouseUp(with: try mouseEvent(.leftMouseUp, modifiers: .option))
        XCTAssertTrue(recorder.sent.isEmpty, "rien ne doit partir vers tmux")

        terminal.selectAll()
        XCTAssertFalse(terminal.allowMouseReporting)
        terminal.selectNone()
        XCTAssertTrue(terminal.allowMouseReporting, "la molette doit revenir à tmux")
    }

    /// Une sortie continue — le spinner de Claude — n'efface pas la sélection
    /// avant qu'on l'ait copiée. La molette revient à tmux quand elle tombe.
    func testASelectionSurvivesStreamingOutput() throws {
        let pane = PaddedTerminalView(inset: 0)
        pane.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        pane.layout()
        let terminal = pane.terminalView
        terminal.feed(text: "à copier\r\n")

        terminal.selectAll()
        XCTAssertFalse(terminal.allowMouseReporting, "une sélection affichée garde la souris")

        terminal.feed(text: "\r⠋ Thinking…\r\n")
        XCTAssertTrue(terminal.selectionActive, "la sortie ne doit pas effacer la sélection")

        terminal.selectNone()
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

    /// Un clic dans le vide copie une sélection de blancs : elle n'écrase
    /// pas la copie précédente.
    func testABlankCopyLeavesTheClipboardAlone() {
        XCTAssertNil(TerminalPane.clipboardText(from: Data()))
        XCTAssertNil(TerminalPane.clipboardText(from: Data("  \n\n \t".utf8)))
        XCTAssertEqual(TerminalPane.clipboardText(from: Data(" ls -la\n".utf8)), " ls -la\n",
                       "le texte copié reste tel quel, blancs compris")
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
