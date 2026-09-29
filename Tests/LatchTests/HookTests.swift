//
//  HookTests.swift
//  LatchTests
//
//  Les hooks Claude Code du §10 : ce qu'on lit du flux, ce qu'on en retient, et
//  ce que le script d'installation promet de ne pas casser.
//

import Foundation
import XCTest

@testable import Latch

final class HookEventTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    func testParsesAToolUseEvent() throws {
        let event = try XCTUnwrap(
            HookEvent.parse(
                line: line([
                    "hook_event_name": "PreToolUse",
                    "session_id": "abc123",
                    "cwd": "/home/alex/api",
                    "tool_name": "Edit",
                    "tool_input": ["file_path": "/home/alex/api/main.py"],
                ])
            )
        )
        XCTAssertEqual(event.kind, .preToolUse)
        XCTAssertEqual(event.sessionID, "abc123")
        XCTAssertEqual(event.toolName, "Edit")
        XCTAssertEqual(event.filePath, "/home/alex/api/main.py")
        XCTAssertEqual(event.cwd, "/home/alex/api")
    }

    /// Les outils ne nomment pas leur cible de la même façon.
    func testFindsThePathUnderItsSeveralNames() throws {
        for key in ["file_path", "path", "notebook_path"] {
            let event = try XCTUnwrap(
                HookEvent.parse(
                    line: line([
                        "hook_event_name": "PostToolUse",
                        "tool_input": [key: "/srv/x.py"],
                    ])
                )
            )
            XCTAssertEqual(event.filePath, "/srv/x.py", "clé « \(key) »")
        }
    }

    func testToolWithoutAPathHasNoFile() throws {
        let event = try XCTUnwrap(
            HookEvent.parse(
                line: line([
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_input": ["command": "ls"],
                ])
            )
        )
        XCTAssertNil(event.filePath)
    }

    /// Un journal tronqué par une déconnexion ne doit pas faire tomber l'app.
    func testRefusesGarbageWithoutCrashing() {
        XCTAssertNil(HookEvent.parse(line: ""))
        XCTAssertNil(HookEvent.parse(line: "   "))
        XCTAssertNil(HookEvent.parse(line: "{\"incomplet\""))
        XCTAssertNil(HookEvent.parse(line: "[1, 2, 3]"))
        // Du JSON valide, mais qui n'est pas un événement de hook.
        XCTAssertNil(HookEvent.parse(line: #"{"autre": "chose"}"#))
    }

    func testUnknownEventsAreKeptButNotInterpreted() throws {
        let event = try XCTUnwrap(
            HookEvent.parse(line: line(["hook_event_name": "PreCompact"]))
        )
        XCTAssertEqual(event.kind, .unknown)
        XCTAssertEqual(event.rawEvent, "PreCompact")
    }

    /// Le §10 veut prévenir « quand une permission est attendue » : c'est
    /// l'événement `Notification` qui la porte.
    func testRecognisesAPermissionPrompt() throws {
        let awaiting = try XCTUnwrap(
            HookEvent.parse(
                line: line([
                    "hook_event_name": "Notification",
                    "message": "Claude needs your permission to use Bash",
                ])
            )
        )
        XCTAssertTrue(awaiting.isAwaitingPermission)

        let idle = try XCTUnwrap(
            HookEvent.parse(
                line: line([
                    "hook_event_name": "Notification",
                    "message": "Claude is waiting for your input",
                ])
            )
        )
        XCTAssertFalse(idle.isAwaitingPermission)
    }
}

final class ClaudeActivityTests: XCTestCase {

    private func event(_ kind: String, tool: String? = nil, path: String? = nil, message: String? = nil)
        -> HookEvent
    {
        var event = HookEvent(kind: HookEvent.Kind(rawEvent: kind), rawEvent: kind)
        event.toolName = tool
        event.filePath = path
        event.message = message
        return event
    }

    func testSessionStartAndEndFrameTheActivity() {
        var activity = ClaudeActivity()
        XCTAssertFalse(activity.isActive)

        activity.apply(event("SessionStart"))
        XCTAssertTrue(activity.isActive)

        activity.apply(event("SessionEnd"))
        XCTAssertFalse(activity.isActive)
        XCTAssertNil(activity.currentFile)
    }

    /// « Fichier en cours de modification, affiché en direct. »
    func testTracksTheFileBeingEdited() {
        var activity = ClaudeActivity()
        activity.apply(event("PreToolUse", tool: "Edit", path: "/srv/api/main.py"))

        XCTAssertEqual(activity.currentFile, "/srv/api/main.py")
        XCTAssertEqual(activity.currentFileName, "main.py")
        XCTAssertEqual(activity.currentTool, "Edit")

        activity.apply(event("PostToolUse", tool: "Edit"))
        XCTAssertNil(activity.currentTool, "l'outil est fini")
        XCTAssertEqual(activity.currentFile, "/srv/api/main.py", "le dernier fichier reste affiché")
    }

    /// Un outil sans fichier ne doit pas effacer le dernier fichier connu.
    func testAToollessEventKeepsTheLastFile() {
        var activity = ClaudeActivity()
        activity.apply(event("PreToolUse", tool: "Edit", path: "/srv/a.py"))
        activity.apply(event("PreToolUse", tool: "Bash"))
        XCTAssertEqual(activity.currentFile, "/srv/a.py")
    }

    func testPermissionIsRaisedAndClearedByTheNextTurn() {
        var activity = ClaudeActivity()
        activity.apply(event("Notification", message: "needs your permission"))
        XCTAssertTrue(activity.isAwaitingPermission)

        activity.apply(event("Stop"))
        XCTAssertFalse(activity.isAwaitingPermission)
    }

    /// Un événement d'outil suffit à savoir que Claude tourne, même si le
    /// `SessionStart` a été manqué — l'app a pu se connecter en cours de route.
    func testAToolEventIsEnoughToConsiderClaudeActive() {
        var activity = ClaudeActivity()
        activity.apply(event("PreToolUse", tool: "Read"))
        XCTAssertTrue(activity.isActive)
    }
}

final class HookInstallerTests: XCTestCase {

    /// Les quatre du §10, plus les deux sans lesquels « prévenir quand une
    /// tâche se termine ou qu'une permission est attendue » est impossible.
    func testWatchesTheEventsTheSpecNeeds() {
        for event in ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse"] {
            XCTAssertTrue(HookInstaller.events.contains(event), event)
        }
        XCTAssertTrue(HookInstaller.events.contains("Stop"))
        XCTAssertTrue(HookInstaller.events.contains("Notification"))
    }

    /// Un hook qui échoue interrompt Claude Code : celui-ci sort toujours à 0.
    func testHookAlwaysExitsCleanly() {
        XCTAssertTrue(HookInstaller.hookScript.contains("exit 0"))
    }

    /// Le journal sert à l'affichage en direct, pas à l'archivage.
    func testHookBoundsTheLogFile() {
        XCTAssertTrue(HookInstaller.hookScript.contains("262144"))
        XCTAssertTrue(HookInstaller.hookScript.contains("tail -c"))
    }

    /// Il n'y a rien de pire que d'effacer les hooks d'un utilisateur qui en
    /// avait déjà.
    func testMergeScriptPreservesExistingHooksAndBacksUp() {
        let script = HookInstaller.settingsMergeScript
        XCTAssertTrue(script.contains("setdefault"))
        XCTAssertTrue(script.contains("latch-backup"))
        XCTAssertFalse(script.contains("json.dump({\"hooks\""), "écrasement pur et simple")
    }

    func testInstallCommandRefusesToRunWithoutPython() {
        XCTAssertTrue(HookInstaller.installCommand.contains("command -v python3"))
    }

    /// Le direct, pas un rejeu de tout l'historique.
    func testFollowCommandStartsAtTheEnd() {
        XCTAssertTrue(HookInstaller.followCommand.contains("tail -n0 -F"))
        XCTAssertTrue(HookInstaller.followCommand.contains("touch"))
    }

    // MARK: Le script, exécuté pour de vrai

    /// On fait tourner le hook comme Claude Code le ferait : une charge JSON
    /// sur l'entrée standard, et on regarde le journal.
    func testHookWritesOneLinePerEvent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let hookURL = home.appendingPathComponent("hook.sh")
        try HookInstaller.hookScript.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hookURL.path
        )

        // Une charge sur plusieurs lignes, comme un JSON indenté le serait.
        let payload = """
            {
              "hook_event_name": "PreToolUse",
              "tool_name": "Edit",
              "tool_input": {"file_path": "/srv/a.py"}
            }
            """

        for _ in 0..<2 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [hookURL.path]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]

            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        let log = try String(
            contentsOf: home.appendingPathComponent(".latch/events.jsonl"), encoding: .utf8
        )
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "une ligne par événement, quoi qu'il arrive à la charge")

        let event = try XCTUnwrap(HookEvent.parse(line: String(lines[0])))
        XCTAssertEqual(event.kind, .preToolUse)
        XCTAssertEqual(event.filePath, "/srv/a.py")
    }
}

// MARK: - Le script de fusion, exécuté pour de vrai

final class HookMergeScriptTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Exécute le script de fusion avec un `HOME` de test.
    @discardableResult
    private func runMerge() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()
        input.fileHandleForWriting.write(Data(HookInstaller.settingsMergeScript.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func settings() throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testFirstRunInstallsEveryEvent() throws {
        let message = try runMerge()
        XCTAssertTrue(message.contains("6 hooks installes"), message)

        let hooks = try XCTUnwrap(settings()["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.events))
    }

    /// Le cas qui a induit en erreur : rejouer l'installation annonçait
    /// « 0 hook(s) ajouté(s) », ce qui se lit comme « ça n'a rien fait ».
    func testSecondRunSaysEverythingIsAlreadyThere() throws {
        try runMerge()
        let message = try runMerge()
        XCTAssertTrue(message.contains("deja en place"), message)
        XCTAssertFalse(message.contains("0 hook"), message)

        // Et rien n'a été dupliqué au passage.
        let hooks = try XCTUnwrap(settings()["hooks"] as? [String: Any])
        for event in HookInstaller.events {
            let matchers = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(matchers.count, 1, "événement \(event) dupliqué")
        }
    }

    /// Une installation partielle se raconte telle qu'elle est.
    func testPartialInstallationReportsBothNumbers() throws {
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try #"{"hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "PLACEHOLDER"}]}]}}"#
            .replacingOccurrences(
                of: "PLACEHOLDER", with: home.appendingPathComponent(".latch/hook.sh").path
            )
            .write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let message = try runMerge()
        XCTAssertTrue(message.contains("5 ajoutes"), message)
        XCTAssertTrue(message.contains("1 deja"), message)
    }

    /// Les réglages qui n'appartiennent pas à Latch survivent, et une copie est
    /// mise de côté avant toute écriture.
    func testExistingSettingsAreKeptAndBackedUp() throws {
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try #"{"theme": "dark", "hooks": {"PreCompact": [{"hooks": [{"command": "autre"}]}]}}"#
            .write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        try runMerge()
        let merged = try settings()
        XCTAssertEqual(merged["theme"] as? String, "dark")

        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreCompact"], "un hook étranger a été perdu")
        XCTAssertNotNil(hooks["SessionStart"])

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: claude.appendingPathComponent("settings.json.latch-backup").path
            )
        )
    }

    /// Un fichier illisible n'est pas écrasé : on sort en le disant.
    func testAnUnreadableSettingsFileIsLeftAlone() throws {
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let path = claude.appendingPathComponent("settings.json")
        try "pas du JSON".write(to: path, atomically: true, encoding: .utf8)

        let message = try runMerge()
        XCTAssertTrue(message.contains("illisible"), message)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "pas du JSON")
    }
}
