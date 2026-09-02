//
//  ContentView.swift
//  Latch
//
//  L'assemblage du §9.1 : barre latérale, onglets, terminal, barre d'état — et,
//  à droite, le panneau d'amélioration du §6, qui ne bloque rien.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()

            VStack(spacing: 0) {
                // La barre de titre est transparente et le contenu passe
                // dessous : sans cette réserve, les onglets disparaissent
                // derrière les feux de circulation.
                Color.latchBackground.frame(height: 28)

                TabBarView()

                if app.currentDegradation.isDegraded {
                    DegradationBanner(
                        degradation: app.currentDegradation,
                        target: app.currentTarget
                    )
                }

                terminalArea

                StatusBar()
            }
            .frame(maxWidth: .infinity)

            if let target = app.upgradingTarget {
                UpgradePanelView(target: target)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.latchBackground)
        .background(WindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeOut(duration: 0.16), value: app.upgradingTarget)
        .sheet(item: $app.editedShortcut) { shortcut in
            BuilderView(shortcut: shortcut)
                .environmentObject(app)
        }
        .alert(
            "Latch",
            isPresented: Binding(
                get: { app.errorMessage != nil },
                set: { if !$0 { app.errorMessage = nil } }
            ),
            actions: { Button("D'accord") { app.errorMessage = nil } },
            message: { Text(app.errorMessage ?? "") }
        )
    }

    /// Tous les onglets restent montés : basculer d'onglet ne doit pas tuer un
    /// pseudo-terminal ni relancer une connexion. Ils partagent le même cadre,
    /// donc la géométrie annoncée à tmux reste juste.
    private var terminalArea: some View {
        ZStack {
            Color(app.store.activeTheme.background.nsColor)

            ForEach(app.tabs) { session in
                let isSelected = session.id == app.selectedTabID
                TerminalPane(session: session, style: app.store.terminalStyle)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }

            if app.tabs.isEmpty {
                EmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - État vide

private struct EmptyState: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 10) {
            Text("Your sessions, still running.")
                .font(.system(size: 13))
                .foregroundStyle(Color.latchTextDim)

            Text(app.store.shortcuts.isEmpty
                ? "Crée une session pour t'accrocher à un serveur."
                : "Choisis une session dans la barre latérale.")
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextFaint)

            if app.store.shortcuts.isEmpty {
                Button("Nouvelle session") { app.newShortcut() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Barre d'état

/// SPEC §9.1 : très discrète. L'état Claude Code, la branche git et la latence
/// viendront des hooks (§10, v0.3).
private struct StatusBar: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            if let session = app.selectedTab {
                SessionStatus(session: session)

                if let activity = app.claudeActivity(on: session.host) {
                    ClaudeIndicator(activity: activity)
                }

                // §9.1 : branche git, diff, latence — dans cet ordre, et
                // seulement quand on les connaît. Un vide vaut mieux qu'un
                // chiffre inventé.
                if let repository = app.repository(for: session) {
                    Label(repository.summary, systemImage: "arrow.triangle.branch")
                        .labelStyle(StatusLabelStyle())
                        .foregroundStyle(
                            repository.isDirty ? Color.latchAccent : Color.latchTextFaint
                        )
                }

                if let latency = app.latency(on: session.host) {
                    Text(latency)
                        .foregroundStyle(Color.latchTextFaint)
                }
            } else {
                Text("aucune session")
                    .foregroundStyle(Color.latchTextFaint)
            }

            if case .failed(let reason) = app.selectedTab?.connection ?? .idle {
                Text(reason)
                    .foregroundStyle(Color.latchAccent)
                    .lineLimit(1)
                Button("Réessayer") { app.selectedTab?.reconnectNow() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.latchAccent)
            }

            Spacer()

            if let error = app.store.lastError {
                Text(error)
                    .foregroundStyle(Color.latchAccent)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.latchSurface)
    }
}

/// L'indicateur du §10, alimenté par les hooks : actif, fichier en cours, et
/// l'attente d'une permission — le seul cas qui mérite d'attirer l'œil.
private struct ClaudeIndicator: View {
    let activity: ClaudeActivity

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(activity.isAwaitingPermission ? Color.latchAccent : Color.latchClaude)
                .frame(width: 6, height: 6)

            Text(activity.isAwaitingPermission ? "Claude attend" : "Claude Code")
                .foregroundStyle(activity.isAwaitingPermission ? Color.latchAccent : Color.latchClaude)

            if let file = activity.currentFileName {
                Text(file)
                    .foregroundStyle(Color.latchTextFaint)
                    .lineLimit(1)
            }
        }
    }
}

/// Une icône minuscule collée à son texte : la barre d'état doit rester
/// discrète (§9.1).
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

private struct SessionStatus: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(session.title)
                .foregroundStyle(Color.latchTextDim)

            if !session.host.isEmpty {
                Text(session.host)
                    .foregroundStyle(Color.latchTextFaint)
            }

            if let notice = session.notice {
                Text(notice)
                    .foregroundStyle(Color.latchTextFaint)
                    .lineLimit(1)
            }

            Spacer()

            if session.size.cols > 0 {
                Text("\(session.size.cols)×\(session.size.rows)")
                    .foregroundStyle(Color.latchTextFaint)
            }

            Text(label)
                .foregroundStyle(Color.latchTextFaint)
        }
    }

    private var color: Color {
        switch session.connection {
        case .connected: return .latchSuccess
        case .degraded, .failed: return .latchAccent
        case .connecting, .reconnecting: return .latchClaude
        case .idle: return .latchTextFaint
        }
    }

    private var label: String {
        if case .idle = session.connection, let code = session.lastExitCode {
            return code == 0 ? "terminé" : "terminé (\(code))"
        }
        return session.connection.label
    }
}
