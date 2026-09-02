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
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)

            Text(session.title)
                .font(.system(size: 11.5))
                .foregroundStyle(isSelected ? Color.latchText : Color.latchTextDim)
                .lineLimit(1)

            // La croix n'apparaît qu'au survol : au repos, la barre reste calme.
            Button {
                app.close(tabID: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.latchTextDim)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(isSelected ? Color.latchSurfaceHigh : Color.latchBackground)
        .contentShape(Rectangle())
        .onTapGesture { app.selectedTabID = session.id }
        .onHover { isHovering = $0 }
    }

    private var dotColor: Color {
        switch session.connection {
        case .connected: return .latchSuccess
        case .degraded: return .latchAccent
        case .connecting, .reconnecting: return .latchClaude
        case .failed: return .latchAccent
        case .idle: return .latchTextFaint
        }
    }
}
