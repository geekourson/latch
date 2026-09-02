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
                        LocalSectionHeader()
                        ForEach(loose) { shortcut in
                            ShortcutRow(shortcut: shortcut)

                            ForEach(app.liveWindows(on: "",
                                                    session: shortcut.connection.tmuxSession)) { window in
                                WindowRow(window: window, host: "")
                            }
                        }

                        ForEach(app.orphanSessions(on: "")) { session in
                            OrphanRow(session: session, host: "")
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

    @State private var confirmsRemoval = false

    private var shortcutCount: Int { app.store.shortcuts(for: server).count }

    /// Retirer un serveur ne touche **rien** sur la machine distante : ni les
    /// sessions tmux, ni les clés, ni les hooks. C'est une entrée de la barre
    /// latérale qui disparaît, et rien d'autre — les orphelines n'ont donc pas
    /// à être rangées avant.
    private var removalExplanation: String {
        var parts = [localized(
            "Rien n'est touché sur l'hôte : les sessions tmux, les clés et les hooks restent en place.")]
        let orphans = app.orphanSessions(on: server.sshAlias).count
        if orphans > 0 {
            parts.append(String(
                format: localized("Ses %d session(s) sans raccourci ne sont pas fermées."), orphans))
        }
        if shortcutCount > 0 {
            parts.append(String(
                format: localized("Ses %d raccourci(s) peuvent être gardés ou retirés avec lui."),
                shortcutCount))
        }
        parts.append(localized("Un serveur retiré revient dès qu'un raccourci le désigne à nouveau."))
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                StatusDot(status: app.status(of: server))
                Text(server.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.latchText)

                if let activity = app.claudeActivity(on: server.sshAlias) {
                    ClaudeDot(activity: activity)
                }

                Spacer(minLength: 0)
                if needsUpgrade {
                    Button {
                        app.upgradingTarget = .server(server)
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
                Button("Améliorer cet hôte…") { app.upgradingTarget = .server(server) }
                Divider()
                Button("Nouvelle session ici") { app.newShortcut(host: server.sshAlias) }
                Divider()
                Button("Retirer ce serveur…", role: .destructive) { confirmsRemoval = true }
            }
            .confirmationDialog(
                "Retirer « \(server.name) » de la barre latérale ?",
                isPresented: $confirmsRemoval,
                titleVisibility: .visible
            ) {
                if shortcutCount > 0 {
                    Button("Retirer avec ses \(shortcutCount) raccourci(s)", role: .destructive) {
                        app.removeServer(server, withShortcuts: true)
                    }
                }
                Button("Retirer le serveur seul") {
                    app.removeServer(server, withShortcuts: false)
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text(removalExplanation)
            }

            ForEach(app.store.shortcuts(for: server)) { shortcut in
                ShortcutRow(shortcut: shortcut)

                // Les vraies fenêtres tmux, telles que le serveur les voit.
                ForEach(app.liveWindows(on: server.sshAlias,
                                        session: shortcut.connection.tmuxSession)) { window in
                    WindowRow(window: window, host: server.sshAlias)
                }
            }

            ForEach(app.orphanSessions(on: server.sshAlias)) { session in
                OrphanRow(session: session, host: server.sshAlias)
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

                // Le témoin du serveur dit qu'une session veut quelque chose ;
                // celui-ci dit laquelle.
                if let activity = app.claudeActivity(
                    inSession: shortcut.connection.tmuxSession,
                    on: shortcut.connection.host
                ) {
                    ClaudeDot(activity: activity)
                }

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
            if isOpen {
                Button("Nouvelle fenêtre") {
                    app.newWindow(
                        inSession: shortcut.connection.tmuxSession,
                        on: shortcut.connection.host
                    )
                }
                Divider()
            }
            Button("Modifier…") { app.editedShortcut = shortcut }
            Button("Supprimer", role: .destructive) {
                app.store.remove(shortcutID: shortcut.id)
            }
        }
    }
}

/// Une fenêtre tmux réelle (§12, v0.4). Cliquer bascule la session distante
/// dessus ; le terminal suit tout seul, c'est tmux qui décide de ce qu'il
/// affiche.
private struct WindowRow: View {
    @EnvironmentObject private var app: AppState
    let window: LiveWindow
    let host: String

    @State private var isRenaming = false
    @State private var newName = ""
    @State private var confirmsClosing = false

    var body: some View {
        HStack(spacing: 5) {
            Text("\(window.index)")
                .foregroundStyle(Color.latchTextFaint)

            if isRenaming {
                TextField("nom", text: $newName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.latchText)
                    .onSubmit { commitRename() }
            } else {
                Text(window.name)
                    .foregroundStyle(window.isActive ? Color.latchText : Color.latchTextDim)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let command = window.currentCommand, command != window.name {
                    Text(command)
                        .foregroundStyle(Color.latchTextFaint)
                        .lineLimit(1)
                        .layoutPriority(0)
                }
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.leading, 28)
        .padding(.trailing, 6)
        // Une cible cliquable de deux pixels de haut n'est pas cliquable.
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(window.isActive ? Color.latchSurface : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { app.select(window, on: host) } }
        .contextMenu {
            Button("Renommer…") {
                newName = window.name
                isRenaming = true
            }
            Button("Nouvelle fenêtre ici") { app.newWindow(inSession: window.session, on: host) }
            if app.shortcut(forSession: window.session, on: host) != nil {
                Button("Ajouter au raccourci…") { app.rememberWindow(window, on: host) }
            }
            Divider()
            Button("Fermer la fenêtre…", role: .destructive) { confirmsClosing = true }
        }
        .confirmationDialog(
            "Fermer la fenêtre « \(window.name) » ?",
            isPresented: $confirmsClosing,
            titleVisibility: .visible
        ) {
            Button("Fermer", role: .destructive) { app.closeWindow(window, on: host) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ce qui y tourne sera interrompu.")
        }
    }

    private func commitRename() {
        app.renameWindow(window, to: newName, on: host)
        isRenaming = false
    }
}

/// Une session tmux que plus aucun raccourci ne désigne. Elle existe, elle
/// occupe le serveur, et sans cette ligne personne ne la verrait jamais.
///
/// Latch ne la ferme pas de lui-même : derrière un nom oublié peut tourner un
/// travail qui compte, et tmux ne dit pas la différence.
private struct OrphanRow: View {
    @EnvironmentObject private var app: AppState
    let session: LiveSession
    let host: String

    @State private var confirmsClosing = false

    var body: some View {
        HStack(spacing: 6) {
            // Le nom passe avant l'âge : c'est lui qui permet de reconnaître la
            // session, et 180 px ne suffisent pas toujours aux deux.
            Text(session.name)
                .foregroundStyle(Color.latchTextFaint)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(session.shortAge)
                .foregroundStyle(Color.latchTextFaint.opacity(0.7))
                .lineLimit(1)
                .layoutPriority(0)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .italic()
        .padding(.leading, 15)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help("Session sans raccourci — \(session.summary)")
        .contextMenu {
            Button("Créer un raccourci ici") { app.adopt(session, on: host) }
            Divider()
            Button("Fermer la session…", role: .destructive) { confirmsClosing = true }
        }
        .confirmationDialog(
            "Fermer la session « \(session.name) » ?",
            isPresented: $confirmsClosing,
            titleVisibility: .visible
        ) {
            Button("Fermer la session", role: .destructive) {
                app.closeSession(session, on: host)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: localized("%@. Tout ce qui y tourne sera interrompu, et ce qui n'a pas été enregistré sera perdu."),
                    session.summary
                )
            )
        }
    }
}

// MARK: - Décor

/// Le Mac est un hôte comme un autre : même pastille, même accès au panneau
/// d'amélioration quand il lui manque tmux (§6).
private struct LocalSectionHeader: View {
    @EnvironmentObject private var app: AppState

    private var degradation: Degradation {
        ServerCapabilities.degradation(for: LocalTools.probe())
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(degradation.isDegraded ? Color.latchAccent : Color.latchTextFaint)
                .frame(width: 6, height: 6)

            Text("local")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.latchText)

            Spacer(minLength: 0)

            if degradation.isDegraded {
                Button {
                    app.upgradingTarget = .localMac
                } label: {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.latchAccent)
                }
                .buttonStyle(.plain)
                .help(LocalTools.missingTmuxMessage)
            }
        }
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
