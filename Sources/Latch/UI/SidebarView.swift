//
//  SidebarView.swift
//  Latch
//
//  SPEC §9.1 : ~180 px, **sans bordure** — la séparation se fait par le vide.
//  Serveurs en gras, sessions indentées en mono en dessous, une pastille d'état
//  par serveur.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(app.store.servers) { server in
                        ServerSection(server: server)
                    }

                    let loose = app.store.unattachedShortcuts
                    if !loose.isEmpty {
                        if !app.store.servers.isEmpty { Spacer().frame(height: 14) }
                        SectionHeader(title: "local")
                        ForEach(loose) { shortcut in
                            ShortcutRow(shortcut: shortcut)
                        }
                    }

                    if app.store.servers.isEmpty && loose.isEmpty {
                        EmptySidebar()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 34)  // sous les feux de circulation
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            Button {
                app.newShortcut()
            } label: {
                Label("Nouvelle session", systemImage: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 180)
        .background(Color.latchBackground)
    }
}

// MARK: - Serveur

private struct ServerSection: View {
    @EnvironmentObject private var app: AppState
    let server: Server

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                StatusDot(status: app.status(of: server))
                Text(server.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.latchText)
                Spacer(minLength: 0)
                if needsUpgrade {
                    Button {
                        app.upgradingServerID = server.id
                    } label: {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.latchAccent)
                    }
                    .buttonStyle(.plain)
                    .help(ServerCapabilities.degradation(for: server.probe).consequence)
                }
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Sonder à nouveau") {
                    Task { await app.store.probe(serverID: server.id, force: true) }
                }
                Button("Améliorer cet hôte…") { app.upgradingServerID = server.id }
                Divider()
                Button("Nouvelle session ici") { app.newShortcut(host: server.sshAlias) }
            }

            ForEach(app.store.shortcuts(for: server)) { shortcut in
                ShortcutRow(shortcut: shortcut)
            }
        }
        .padding(.top, 8)
    }

    private var needsUpgrade: Bool {
        guard !server.skipUpgradePrompt else { return false }
        return ServerCapabilities.degradation(for: server.probe).isDegraded
    }
}

// MARK: - Raccourci

private struct ShortcutRow: View {
    @EnvironmentObject private var app: AppState
    let shortcut: Shortcut

    private var isOpen: Bool {
        app.tabs.contains { $0.shortcutID == shortcut.id }
    }

    private var isSelected: Bool {
        app.selectedTab?.shortcutID == shortcut.id
    }

    var body: some View {
        Button {
            Task { await app.open(shortcut) }
        } label: {
            HStack(spacing: 6) {
                Text(shortcut.connection.tmuxSession)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.latchText : Color.latchTextDim)
                Spacer(minLength: 0)
                if isOpen {
                    Circle()
                        .fill(Color.latchSuccess)
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.leading, 15)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.latchSurfaceHigh : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut.name)
        .contextMenu {
            Button("Modifier…") { app.editedShortcut = shortcut }
            Button("Supprimer", role: .destructive) {
                app.store.remove(shortcutID: shortcut.id)
            }
        }
    }
}

// MARK: - Décor

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.latchText)
            .padding(.vertical, 4)
    }
}

/// Vert (connecté), ambre (veille ou dégradé), gris (hors ligne).
private struct StatusDot: View {
    let status: AppState.ServerStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var color: Color {
        switch status {
        case .connected: return .latchSuccess
        case .degraded: return .latchAccent
        case .offline: return .latchTextFaint
        }
    }
}

private struct EmptySidebar: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aucun serveur")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.latchTextDim)
            Text("Latch lit les alias de ~/.ssh/config au premier lancement.")
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}
