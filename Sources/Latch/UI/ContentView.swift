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
                // dessous : cette bande la remplace, et porte les dispositions.
                ZoneTopBand()
                    .background(Color.latchBackground)

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
        // SwiftUI ne résout pas ses littéraux par `Bundle.localizedString` — le
        // remplacement de classe ne l'atteint pas. Il choisit la localisation
        // du bundle d'après la locale de l'environnement : c'est elle qu'il
        // faut poser, et l'`id` reconstruit l'arbre quand elle change.
        .environment(\.locale, Locale(identifier: app.store.preferences.language.resolved))
        .id(app.store.preferences.language)
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

    /// Les zones, chacune avec son terminal. Tous les terminaux restent
    /// montés, à l'écran ou non : en masquer un ne doit pas couper sa
    /// connexion (voir `ZoneArea`).
    private var terminalArea: some View {
        ZoneArea()
            .padding([.horizontal, .bottom], app.layout.isSingle ? 0 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Le fond s'arrête au cadre : par défaut, il déborderait sous la
            // barre de titre et recouvrirait la bande des dispositions.
            .background(Color.latchBackground, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottomTrailing) {
                if let notice = app.transientNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.latchTextDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.latchSurfaceHigh))
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: app.transientNotice)
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

                if let activity = app.claudeActivity(for: session) {
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
            ClaudeDot(activity: activity, size: 6)

            Text(ClaudeDot.shortWording(for: activity))
                .foregroundStyle(ClaudeDot.color(for: activity))

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

    private var color: Color { session.connection.dotColor }

    private var label: String {
        if case .idle = session.connection, let code = session.lastExitCode {
            return code == 0
                ? localized("terminé")
                : String(format: localized("terminé (%d)"), code)
        }
        return session.connection.label
    }
}
