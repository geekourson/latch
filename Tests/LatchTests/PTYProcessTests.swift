//
//  PTYProcessTests.swift
//  LatchTests
//

import Combine
import XCTest

@testable import Latch

final class PTYProcessTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Collecte toute la sortie d'une commande jusqu'à sa fin.
    private func run(
        _ command: String,
        rows: UInt16 = 24,
        cols: UInt16 = 80,
        timeout: TimeInterval = 10,
        environment: [String: String]? = nil,
        configure: ((PTYProcess) -> Void)? = nil
    ) throws -> (output: String, code: Int32) {
        let pty = PTYProcess()
        var collected = Data()
        var exitCode: Int32?
        let finished = expectation(description: "le process se termine")

        pty.output
            .sink { collected.append($0) }
            .store(in: &cancellables)

        pty.state
            .sink { state in
                if case .exited(let code) = state, exitCode == nil {
                    exitCode = code
                    finished.fulfill()
                }
            }
            .store(in: &cancellables)

        try pty.start(command: command, rows: rows, cols: cols, environment: environment)
        configure?(pty)
        wait(for: [finished], timeout: timeout)

        return (String(decoding: collected, as: UTF8.self), try XCTUnwrap(exitCode))
    }

    func testRunsCommandAndCapturesOutput() throws {
        let result = try run("echo latched-on")
        XCTAssertTrue(result.output.contains("latched-on"), "sortie reçue : \(result.output)")
        XCTAssertEqual(result.code, 0)
    }

    func testReportsNonZeroExitCode() throws {
        XCTAssertEqual(try run("exit 42").code, 42)
    }

    /// Un process tué par un signal est rapporté 128 + N, comme un shell.
    func testReportsSignalAsShellConvention() throws {
        XCTAssertEqual(try run("kill -TERM $$").code, 128 + SIGTERM)
    }

    /// Le process doit voir un vrai TTY, pas un tube — sans quoi tmux refuse
    /// de démarrer (SPEC §5).
    func testChildSeesATerminal() throws {
        let result = try run("test -t 0 && echo tty-ok")
        XCTAssertTrue(result.output.contains("tty-ok"), "sortie reçue : \(result.output)")
    }

    /// `TERM` doit décrire ce que Latch émule, jamais le terminal d'où l'app a
    /// été lancée : le serveur distant n'a pas forcément ce terminfo, et tmux
    /// refuse alors de démarrer.
    func testTermIsForcedAndNotInherited() throws {
        let result = try run(
            "printf 'TERM=%s|PROGRAM=[%s]\\n' \"$TERM\" \"$TERM_PROGRAM\"",
            environment: ["TERM": "xterm-ghostty", "TERM_PROGRAM": "ghostty", "PATH": "/usr/bin:/bin"]
        )
        XCTAssertTrue(result.output.contains("TERM=xterm-256color"), "sortie reçue : \(result.output)")
        XCTAssertTrue(result.output.contains("PROGRAM=[]"), "sortie reçue : \(result.output)")
    }

    func testInitialWindowSizeIsPropagated() throws {
        let result = try run("stty size", rows: 40, cols: 132)
        XCTAssertTrue(result.output.contains("40 132"), "sortie reçue : \(result.output)")
    }

    func testResizeChangesWindowSize() throws {
        // Le shell laisse le temps au redimensionnement d'arriver avant de lire.
        let result = try run("sleep 0.6; stty size", rows: 24, cols: 80) { pty in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                pty.resize(rows: 51, cols: 121)
            }
        }
        XCTAssertTrue(result.output.contains("51 121"), "sortie reçue : \(result.output)")
    }

    /// Ce que l'utilisateur tape doit ressortir tel quel côté process.
    func testSendWritesToTheProcess() throws {
        let result = try run("read -r line; echo got:$line") { pty in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                pty.send(Data("hello\n".utf8))
            }
        }
        XCTAssertTrue(result.output.contains("got:hello"), "sortie reçue : \(result.output)")
    }

    func testTerminateStopsALongRunningProcess() throws {
        let result = try run("sleep 60", timeout: 8) { pty in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                pty.terminate()
            }
        }
        XCTAssertNotEqual(result.code, 0)
    }

    func testStartingTwiceIsRejected() throws {
        let pty = PTYProcess()
        try pty.start(command: "sleep 5")
        XCTAssertThrowsError(try pty.start(command: "echo nope")) { error in
            guard case PTYError.alreadyRunning = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        }
        pty.terminate()
    }
}
