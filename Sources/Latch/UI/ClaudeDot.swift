//
//  ClaudeDot.swift
//  Latch
//
//  Le témoin du §10, partagé par la barre latérale et la barre d'état : deux
//  endroits qui montrent le même état ne doivent pas le montrer de deux
//  façons différentes.
//

import SwiftUI

extension ConnectionState {
    /// La couleur de la pastille d'un onglet. Elle vit ici, à côté de celle de
    /// Claude et de la légende qui les explique toutes les deux.
    var dotColor: Color {
        switch self {
        case .connected: return .latchSuccess
        case .degraded: return .latchAccent
        // Un échec attend une décision, comme Claude quand il bloque.
        case .failed: return .latchAttention
        case .connecting, .reconnecting: return .latchPending
        case .idle: return .latchTextFaint
        }
    }
}

struct ClaudeDot: View {
    let activity: ClaudeActivity
    var size: CGFloat = 5

    var body: some View {
        Group {
            if activity.attention == .reply {
                // Un anneau : il t'attend, mais rien n'est suspendu.
                Circle()
                    .strokeBorder(ClaudeDot.color(for: activity), lineWidth: 1.5)
            } else {
                Circle().fill(ClaudeDot.color(for: activity))
            }
        }
        .frame(width: size, height: size)
        .help(ClaudeDot.wording(for: activity))
    }

    /// Une seule couleur pour « il t'attend » : ajouter une teinte de plus
    /// obligerait à retenir la palette au lieu de la lire. C'est le
    /// remplissage qui dit si quelque chose est suspendu.
    static func color(for activity: ClaudeActivity) -> Color {
        activity.needsAttention ? .latchAttention : .latchClaude
    }

    static func wording(for activity: ClaudeActivity) -> String {
        switch activity.attention {
        case .permission: return localized("Claude attend une autorisation")
        case .reply: return localized("Claude attend ta réponse")
        case .none: return localized("Claude Code est actif")
        }
    }

    /// La forme courte, pour la barre d'état où la place manque.
    static func shortWording(for activity: ClaudeActivity) -> String {
        switch activity.attention {
        case .permission: return localized("Claude attend")
        case .reply: return localized("à toi")
        case .none: return localized("Claude Code")
        }
    }
}
