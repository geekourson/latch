//
//  ClaudeAttentionTests.swift
//  LatchTests
//
//  Les charges utiles de ce fichier sont copiées telles quelles du journal
//  d'un vrai serveur, `~/.latch/events.jsonl`. C'est là qu'on a découvert le
//  défaut : Claude Code distingue `permission_prompt` de `idle_prompt`, et
//  Latch ne reconnaissait que le premier — une question restait donc invisible.
//

import XCTest

@testable import Latch

final class ClaudeAttentionTests: XCTestCase {

    // MARK: - Les lignes réelles

    /// « Claude needs your permission » : un outil est suspendu.
    private let permissionLine = """
        {"session_id":"c51a9d2a-207d-4c10-8953-fcd3998e5b5d",\
        "cwd":"/home/billy/gribouille-model",\
        "prompt_id":"f6ccfd02-a954-4d92-aca1-2e30e3f9a1e7",\
        "hook_event_name":"Notification",\
        "message":"Claude needs your permission",\
        "notification_type":"permission_prompt"}
        """

    /// « Claude is waiting for your input » : une question sans réponse.
    private let idleLine = """
        {"session_id":"18ccfcf8-dc27-4b12-9d4d-2fc994422e04",\
        "cwd":"/home/billy/chess-model",\
        "hook_event_name":"Notification",\
        "message":"Claude is waiting for your input",\
        "notification_type":"idle_prompt"}
        """

    func testAPermissionPromptBlocks() throws {
        let event = try XCTUnwrap(HookEvent.parse(line: permissionLine))
        XCTAssertEqual(event.attention, .permission)
        XCTAssertTrue(event.isAwaitingPermission)
        XCTAssertEqual(event.cwd, "/home/billy/gribouille-model")
    }

    /// Le défaut qu'on corrige : cette ligne ne produisait aucune attente, et
    /// rien n'apparaissait nulle part.
    func testAnIdlePromptIsAQuestionWaitingForAnAnswer() throws {
        let event = try XCTUnwrap(HookEvent.parse(line: idleLine))
        XCTAssertEqual(event.attention, .reply)
        XCTAssertFalse(event.isAwaitingPermission, "une question ne bloque pas un outil")
    }

    /// Un tour qui se termine rend la main, et c'est le signal le plus rapide :
    /// `idle_prompt` n'arrive qu'après un délai d'inactivité.
    func testAFinishedTurnHandsBackControl() throws {
        let line = #"{"hook_event_name":"Stop","session_id":"x","cwd":"/home/billy/api"}"#
        let event = try XCTUnwrap(HookEvent.parse(line: line))
        XCTAssertEqual(event.attention, .reply)
    }

    func testWorkInProgressAwaitsNothing() throws {
        for name in ["PreToolUse", "PostToolUse", "SessionStart"] {
            let line = #"{"hook_event_name":"\#(name)","session_id":"x"}"#
            let event = try XCTUnwrap(HookEvent.parse(line: line), name)
            XCTAssertNil(event.attention, name)
        }
    }

    /// Les versions qui n'envoyaient pas `notification_type` restent lisibles.
    func testTheTextIsReadWhenTheTypeIsMissing() throws {
        let line = #"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#
        XCTAssertEqual(try XCTUnwrap(HookEvent.parse(line: line)).attention, .permission)

        let other = #"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#
        XCTAssertEqual(try XCTUnwrap(HookEvent.parse(line: other)).attention, .reply)
    }

    /// Une notification qu'on ne sait pas lire ne doit pas allumer un témoin :
    /// un voyant qui s'allume pour rien cesse d'être regardé.
    func testAnUnreadableNotificationAwaitsNothing() throws {
        let line = #"{"hook_event_name":"Notification","message":"Compaction terminée"}"#
        XCTAssertNil(try XCTUnwrap(HookEvent.parse(line: line)).attention)
    }

    // MARK: - L'état reconstruit

    func testTheDotFollowsTheLastThingClaudeDid() throws {
        var activity = ClaudeActivity()

        activity.apply(try XCTUnwrap(HookEvent.parse(line: idleLine)))
        XCTAssertEqual(activity.attention, .reply)
        XCTAssertTrue(activity.needsAttention)
        XCTAssertEqual(activity.directory, "/home/billy/chess-model")

        // Une réponse relance le travail : l'attente tombe.
        let tool = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/home/billy/chess-model"}"#
        activity.apply(try XCTUnwrap(HookEvent.parse(line: tool)))
        XCTAssertNil(activity.attention)
        XCTAssertTrue(activity.isActive)
    }

    /// L'autorisation prime : entre les deux, c'est celle qui bloque qu'il
    /// faut montrer.
    func testPermissionOutranksAPendingReply() throws {
        var activity = ClaudeActivity()
        activity.apply(try XCTUnwrap(HookEvent.parse(line: idleLine)))
        activity.apply(try XCTUnwrap(HookEvent.parse(line: permissionLine)))
        XCTAssertEqual(activity.attention, .permission)
    }

    func testTheEndOfASessionClearsEverything() throws {
        var activity = ClaudeActivity()
        activity.apply(try XCTUnwrap(HookEvent.parse(line: permissionLine)))

        let end = #"{"hook_event_name":"SessionEnd","session_id":"x"}"#
        activity.apply(try XCTUnwrap(HookEvent.parse(line: end)))
        XCTAssertFalse(activity.isActive)
        XCTAssertNil(activity.attention)
    }

    func testStrongerKeepsTheBlockingOne() {
        XCTAssertEqual(ClaudeAttention.stronger(.reply, .permission), .permission)
        XCTAssertEqual(ClaudeAttention.stronger(.permission, .reply), .permission)
        XCTAssertEqual(ClaudeAttention.stronger(nil, .reply), .reply)
        XCTAssertEqual(ClaudeAttention.stronger(.reply, nil), .reply)
        XCTAssertNil(ClaudeAttention.stronger(nil, nil))
    }

    // MARK: - Le rattachement à une session tmux

    /// La ligne que la boucle d'inspection émet pour chaque panneau actif —
    /// relevée sur le serveur de référence.
    func testThePaneDirectoryIsWhatLinksAHookToATmuxSession() {
        let separator = TmuxInspector.separator
        let line = "\(TmuxInspector.pathPrefix)gribouille\(separator)/home/billy/gribouille-model"

        XCTAssertTrue(line.hasPrefix(TmuxInspector.pathPrefix))
        let fields = String(line.dropFirst(TmuxInspector.pathPrefix.count))
            .components(separatedBy: separator)
        XCTAssertEqual(fields, ["gribouille", "/home/billy/gribouille-model"])

        // Et c'est bien le `cwd` que portait l'événement de permission.
        let event = HookEvent.parse(line: permissionLine)
        XCTAssertEqual(event?.cwd, fields[1])
    }

    /// Le répertoire doit être émis même hors dépôt git : `api` tourne dans
    /// `/home/billy`, qui n'est pas un dépôt, et doit quand même se rattacher.
    func testTheWatchCommandEmitsTheDirectoryBeforeAskingGit() {
        let command = TmuxInspector.watchCommand()
        guard let cwdIndex = command.range(of: TmuxInspector.pathPrefix),
              let gitIndex = command.range(of: "rev-parse")
        else { return XCTFail("la boucle n'émet pas le répertoire") }
        XCTAssertLessThan(
            cwdIndex.lowerBound, gitIndex.lowerBound,
            "git peut abandonner la ligne : le répertoire doit sortir avant"
        )
    }
}
