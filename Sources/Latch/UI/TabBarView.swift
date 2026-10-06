//
//  TabBarView.swift
//  Latch
//
//  SPEC §9.1 : fond légèrement plus clair pour l'onglet actif, **aucun
//  séparateur** entre les inactifs.
//

import SwiftUI

struct TabBarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(app.tabs) { session in
                    TabItem(session: session)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 32)
        .background(Color.latchBackground)
    }
}

private struct TabItem: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: TerminalSession
    @State private var isHovering = false

    private var isSelected: Bool { app.selectedTabID == session.id }

    var body: some View {
        // Un `Button`, pas un `.onTapGesture` : dans un conteneur défilant, un
        // geste de tap doit d'abord perdre l'arbitrage contre le défilement
        // avant de se déclencher. Le délai est petit mais se sent à chaque
        // clic, et c'est ce qui rendait le changement d'onglet poussif.
        Button {
            app.selectedTabID = session.id
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.connection.dotColor)
                    .frame(width: 5, height: 5)

                Text(session.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? Color.latchText : Color.latchTextDim)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            // La place de la croix est réservée en permanence : sans ça, le
            // titre se décale au survol et la cible bouge sous le curseur.
            .padding(.trailing, 32)
            .frame(height: 32)
            .background(isSelected ? Color.latchSurfaceHigh : Color.latchBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // La croix est posée par-dessus plutôt qu'imbriquée : un bouton dans
        // le label d'un autre bouton se laisse mal viser.
        .overlay(alignment: .trailing) { closeButton }
        .onHover { isHovering = $0 }
    }

    private var closeButton: some View {
        Button {
            app.close(tabID: session.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color.latchTextDim)
                // Le dessin reste minuscule, la cible fait 26 points : viser
                // une croix de huit pixels à la souris est un exercice.
                .frame(width: 26, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Invisible au repos, mais jamais inerte : une cible qui n'apparaît
        // qu'au survol doit déjà être cliquable quand on l'atteint.
        .opacity(isHovering || isSelected ? 1 : 0)
        .padding(.trailing, 4)
    }
}
