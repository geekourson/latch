//
//  LegendView.swift
//  Latch
//
//  Une pastille de cinq pixels ne s'explique pas toute seule. Les couleurs de
//  Latch forment une grammaire — six mots, pas plus — et elle doit être écrite
//  quelque part plutôt que devinée.
//

import SwiftUI

/// Ce que veut dire chaque pastille, dans l'ordre où on la rencontre.
struct LegendView: View {

    /// Une entrée de la légende : la marque, puis ce qu'elle dit.
    private struct Entry: Identifiable {
        let id = UUID()
        let color: Color
        let isHollow: Bool
        let title: String
        let detail: String

        init(_ color: Color, hollow: Bool = false, _ title: String, _ detail: String) {
            self.color = color
            self.isHollow = hollow
            self.title = title
            self.detail = detail
        }
    }

    /// Les couleurs que la légende explique. Ce qui n'est pas là ne doit pas
    /// apparaître à l'écran : une pastille sans explication est un hiéroglyphe.
    static let explainedColors: Set<Color> = [
        .latchSuccess, .latchPending, .latchAccent, .latchAttention,
        .latchClaude, .latchTextFaint,
    ]

    private var entries: [Entry] {
        [
            Entry(.latchSuccess, localized("Connecté"),
                  localized("Tout ce qui était demandé est en place.")),
            Entry(.latchPending, localized("En cours"),
                  localized("Connexion, ou reconnexion après une veille.")),
            Entry(.latchAccent, localized("Dégradé"),
                  localized("Ça marche, mais moins bien que prévu : mosh ou tmux manque.")),
            Entry(.latchAttention, localized("Bloqué"),
                  localized("Une connexion a échoué, ou Claude Code attend une autorisation.")),
            Entry(.latchAttention, hollow: true, localized("À toi"),
                  localized("Claude Code a rendu la main et attend ta réponse.")),
            Entry(.latchClaude, localized("Claude Code"),
                  localized("Une session Claude Code travaille.")),
            Entry(.latchTextFaint, localized("Inactif"),
                  localized("Rien ne tourne, et rien n'attend.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    mark(entry)
                        // Alignée sur la première ligne de texte, pas sur le
                        // haut du bloc : le point suit le mot qu'il désigne.
                        .alignmentGuide(.firstTextBaseline) { _ in 5 }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.latchText)
                        Text(entry.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.latchTextFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text.paragraph("La pastille pleine dit qu'une action est attendue de toi ; "
                + "l'anneau, que tu peux prendre ton temps.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.latchTextFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func mark(_ entry: Entry) -> some View {
        Group {
            if entry.isHollow {
                Circle().strokeBorder(entry.color, lineWidth: 1.5)
            } else {
                Circle().fill(entry.color)
            }
        }
        .frame(width: 7, height: 7)
    }
}
