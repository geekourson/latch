//
//  ContentView.swift
//  Latch
//
//  v0.1 : une fenêtre, un terminal, une commande codée en dur (SPEC §12).
//  La barre latérale, les onglets et le store arrivent en v0.2.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var session = TerminalSession(
        name: "api",
        command: HardcodedSession.command
    )

    var body: some View {
        VStack(spacing: 0) {
            TerminalPane(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar(session: session)
        }
        .background(Color.latchBackground)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// La commande de la v0.1. Elle sera remplacée par `CommandBuilder` en v0.2.
enum HardcodedSession {
    /// La SPEC §12 vise `mosh billy -- tmux new -A -s api`. Le serveur de
    /// référence n'a pas `mosh-server` et le Mac n'a pas `mosh-client` — le
    /// binaire embarqué est une tâche de v0.3 (SPEC §7). On applique donc dès
    /// maintenant la cascade de dégradation du §6 : tmux existe, on passe par
    /// `ssh -t`, et la session survit quand même à la fermeture de l'onglet.
    static let command = #"ssh -t billy "tmux new -A -s api""#
}

// MARK: - Barre d'état

/// Version minimale de la barre basse du §9.1 : l'état Claude Code, la branche
/// git et la latence viendront avec les hooks (v0.3).
private struct StatusBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(session.title)
                .foregroundStyle(Color.latchTextDim)

            Spacer()

            if session.size.cols > 0 {
                Text("\(session.size.cols)×\(session.size.rows)")
                    .foregroundStyle(Color.latchTextFaint)
            }

            Text(statusLabel)
                .foregroundStyle(Color.latchTextFaint)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.latchSurface)
    }

    private var statusColor: Color {
        switch session.state {
        case .running: return .latchSuccess
        case .idle: return .latchTextFaint
        case .exited: return .latchAccent
        }
    }

    private var statusLabel: String {
        switch session.state {
        case .idle: return "en attente"
        case .running: return "latched on"
        case .exited(let code): return code == 0 ? "terminé" : "terminé (\(code))"
        }
    }
}
