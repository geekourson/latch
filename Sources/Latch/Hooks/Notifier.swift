//
//  Notifier.swift
//  Latch
//
//  SPEC §10 : « notification macOS + rebond du Dock quand une tâche se termine
//  ou qu'une permission est attendue ».
//
//  Le rebond du Dock marche toujours. La notification, elle, dépend d'une
//  autorisation que l'utilisateur peut refuser et qu'une app non signée
//  n'obtient pas forcément : c'est un bonus, pas le mécanisme principal.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
enum Notifier {

    private static var didRequestAuthorization = false

    /// Demandée une seule fois, et sans bloquer : un refus ne doit rien casser.
    static func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Ne rebondit que si Latch n'est pas déjà devant : prévenir quelqu'un qui
    /// regarde l'écran est du bruit.
    static func notify(title: String, body: String, bounce: Bool = true) {
        guard !NSApp.isActive else { return }

        if bounce {
            NSApp.requestUserAttention(.informationalRequest)
        }

        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Une permission attendue mérite l'attention critique : l'icône rebondit
    /// jusqu'à ce qu'on vienne voir, parce que Claude, lui, attend vraiment.
    static func notifyAwaitingPermission(host: String) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.criticalRequest)
        notify(
            title: "Claude Code attend une réponse",
            body: "Une permission est demandée sur \(host).",
            bounce: false
        )
    }

    static func notifyTaskFinished(host: String) {
        notify(title: "Claude Code a terminé", body: "La tâche est finie sur \(host).")
    }
}
