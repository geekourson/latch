//
//  ClaudeDot.swift
//  Latch
//
//  Le témoin du §10, partagé par la barre latérale et la barre d'état : deux
//  endroits qui montrent le même état ne doivent pas le montrer de deux
//  façons différentes.
//

import SwiftUI

struct ClaudeDot: View {
    let activity: ClaudeActivity
    var size: CGFloat = 5

    var body: some View {
        Circle()
            .fill(ClaudeDot.color(for: activity))
            .frame(width: size, height: size)
            .help(ClaudeDot.wording(for: activity))
    }

    /// L'autorisation bloque le travail : elle prend la couleur d'alerte. Une
    /// réponse attendue se distingue quand même de « ça tourne », sinon on ne
    /// sait jamais quelle session mérite le regard.
    static func color(for activity: ClaudeActivity) -> Color {
        switch activity.attention {
        case .permission: return .latchAttention
        case .reply: return .latchAccent
        case .none: return .latchClaude
        }
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
