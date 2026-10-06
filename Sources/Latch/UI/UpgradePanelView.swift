//
//  UpgradePanelView.swift
//  Latch
//
//  Le panneau d'amélioration du SPEC §6.
//
//  Ce n'est **pas** une modale : c'est une colonne à droite, la session reste
//  utilisable derrière. Latch n'installe rien elle-même — elle propose une
//  commande exacte, que l'utilisateur copie ou tape lui-même dans un vrai TTY.
//  Aucun `sudo -S`, aucun `sshpass`, aucun mot de passe lu ni stocké.
//

import AppKit
import SwiftUI

struct UpgradePanelView: View {
    @EnvironmentObject private var app: AppState
    /// Un serveur, ou le Mac : le §6 s'applique aux deux.
    let target: UpgradeTarget

    @State private var freeformCommand = ""
    @State private var showsHookScript = false
    @State private var confirmsHookInstall = false
    @State private var isInstallingHooks = false
    @State private var hookInstallResult: String?
    @State private var hooksInstalled: Bool?
    @State private var keyWorks: Bool?
    @State private var storedPassword = ""
    @State private var hasStoredPassword = false
    @State private var passwordError: String?

    private var plan: UpgradePlan {
        ServerUpgradePlanner.plan(for: target.probe, wantsMosh: target.wantsMosh)
    }

    /// Le serveur, quand la cible en est un. Les hooks, le serveur MCP et la
    /// case « ne plus proposer » n'ont de sens que là.
    private var server: Server? {
        if case .server(let server) = target { return server }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    diagnostics
                    consequence
                    if plan.hasKnownDistribution {
                        commandBlock
                    } else if !plan.missingPackages.isEmpty {
                        unknownDistributionBlock
                    }
                    if let firewall = plan.firewallCommand {
                        firewallBlock(firewall)
                    }
                    if let claude = plan.claudeCommand {
                        claudeBlock(claude)
                    }
                    offPathBlock

                    // Claude Code tourne aussi sur le Mac : ces deux-là ne
                    // dépendent pas d'une connexion.
                    hooksBlock
                    mcpBlock

                    if server != nil {
                        authenticationBlock
                        localMoshBlock
                        pathHint
                        skipToggle
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 340)
        .background(Color.latchSurface)
        .task(id: target.id) {
            // Les hooks se vérifient des deux côtés : une chaîne vide désigne
            // le Mac. Le trousseau et la clé ssh, eux, n'ont de sens que pour
            // un hôte qu'il faut joindre.
            hooksInstalled = await HookInstaller.isInstalled(on: target.alias ?? "")

            guard let alias = target.alias else { return }
            hasStoredPassword = Keychain.hasPassword(
                alias: alias, account: SSHConfig.user(for: alias)
            )
            keyWorks = await SSHKeySetup.worksWithoutPassword(alias: alias)
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack {
            Text(target.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.latchText)
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.latchTextDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 14)
    }

    // MARK: 1. Diagnostic

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Diagnostic", systemImage: "stethoscope")
                .labelStyle(SectionLabelStyle())

            if plan.diagnostics.isEmpty {
                Text("Cet hôte n'a pas encore été sondé.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextFaint)
            }

            ForEach(plan.diagnostics) { tool in
                HStack(spacing: 6) {
                    Text(tool.isPresent ? "✓" : "✗")
                        .foregroundStyle(tool.isPresent ? Color.latchSuccess : Color.latchAccent)
                    Text(tool.summary)
                        .foregroundStyle(Color.latchText)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5, design: .monospaced))
            }

            if let distribution = plan.distributionName {
                Text(distribution)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.latchTextFaint)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: 2. Conséquence, en une phrase

    private var consequence: some View {
        Text(plan.degradation.consequence)
            .font(.system(size: 12))
            .foregroundStyle(Color.latchTextDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 3. La commande exacte

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(target.commandLocation, systemImage: "terminal")
                .labelStyle(SectionLabelStyle())

            if let command = plan.packageCommand {
                CommandBox(command: command)
                actions(for: command)
            }

            // Sur un Mac sans Homebrew, la commande proposée n'a rien pour
            // s'exécuter : le dire vaut mieux que la laisser échouer.
            if target.isLocal, LocalTools.homebrewPath == nil {
                Text(LocalTools.missingHomebrewMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchAccent)
                    .fixedSize(horizontal: false, vertical: true)
                Link("brew.sh", destination: LocalTools.homebrewURL)
                    .font(.system(size: 11))
                    .tint(Color.latchAccent)
            }
        }
    }

    /// Distribution inconnue : on n'invente aucune commande. On dit ce qu'il
    /// faut, on renvoie à la doc, et on laisse l'utilisateur écrire la sienne.
    private var unknownDistributionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Distribution inconnue", systemImage: "questionmark.circle")
                .labelStyle(SectionLabelStyle())

            Text("Paquets requis : \(plan.missingPackages.joined(separator: ", "))")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color.latchText)

            Link("Documentation d'installation", destination: ServerUpgradePlanner.documentationURL)
                .font(.system(size: 11))
                .tint(Color.latchAccent)

            TextField("Ta commande d'installation…", text: $freeformCommand)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.latchBackground))

            if !freeformCommand.isEmpty {
                actions(for: freeformCommand)
            }
        }
    }

    // MARK: 4. Pare-feu — seulement si mosh est à installer

    private func firewallBlock(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pare-feu — optionnel", systemImage: "shield")
                .labelStyle(SectionLabelStyle())

            Text("mosh a besoin des ports UDP 60000 à 61000.")
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextDim)
                .fixedSize(horizontal: false, vertical: true)

            CommandBox(command: command)
            actions(for: command)
        }
    }

    // MARK: 5. Claude Code — sa propre ligne, et surtout sans sudo

    private func claudeBlock(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Claude Code", systemImage: "sparkles")
                .labelStyle(SectionLabelStyle())

            Text.paragraph("Claude Code n'est dans aucun gestionnaire de paquets. "
                + "Son installeur s'installe dans ton dossier personnel et "
                + "refuse de tourner sous sudo.")
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextDim)
                .fixedSize(horizontal: false, vertical: true)

            CommandBox(command: command)
            actions(for: command)
        }
    }

    // MARK: Outils hors PATH — le piège du §6, en vrai

    /// Un outil installé mais invisible d'un shell non interactif. Latch
    /// l'appelle par son chemin absolu, donc tout marche — mais il vaut mieux
    /// le dire, parce que tout le reste (scripts, cron, autres outils) butera
    /// dessus.
    @ViewBuilder
    private var offPathBlock: some View {
        if !plan.offPathTools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Installés, mais hors du PATH", systemImage: "arrow.triangle.branch")
                    .labelStyle(SectionLabelStyle())

                ForEach(plan.offPathTools.sorted(by: { $0.key < $1.key }), id: \.key) { tool, path in
                    Text("\(tool) → \(path)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.latchText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text.paragraph("Latch les appelle par leur chemin absolu, donc tes "
                    + "sessions fonctionnent. Mais un shell non interactif ne "
                    + "les trouve pas : déplace le PATH de ~/.bashrc vers "
                    + "~/.profile ou ~/.zshenv pour que tout le reste les voie "
                    + "aussi.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Authentification (§11)

    /// L'authentification par clé est la seule que la SPEC accepte par défaut.
    /// Quand elle ne marche pas encore, on propose de la mettre en place —
    /// pas de contourner le problème avec un mot de passe.
    @ViewBuilder
    private var authenticationBlock: some View {
        if let alias = target.alias {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("Authentification", systemImage: "key")
                        .labelStyle(SectionLabelStyle())
                    if keyWorks == true {
                        Text("par clé")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.latchSuccess)
                    } else if keyWorks == false {
                        Text("mot de passe requis")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.latchAccent)
                    }
                }

                if keyWorks == false {
                    Text(SSHKeySetup.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.latchTextDim)
                        .fixedSize(horizontal: false, vertical: true)

                    CommandBox(command: SSHKeySetup.setupCommand(alias: alias))

                    HStack(spacing: 8) {
                        Button("Configurer une clé…") {
                            app.configureKey(on: alias)
                            app.upgradingTarget = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.latchAccent)
                        .controlSize(.small)

                        Button("Copier") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                SSHKeySetup.setupCommand(alias: alias), forType: .string
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    .font(.system(size: 11))

                    if SSHKeySetup.hasKey() {
                        Text(
                            String(
                                format: localized("Une clé existe déjà (%@) : elle sera réutilisée, jamais écrasée."),
                                SSHKeySetup.privateKeyPath
                            )
                        )
                            .font(.system(size: 10))
                            .foregroundStyle(Color.latchTextFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    passwordFallback(alias: alias)
                }
            }
        }
    }

    /// Le dernier recours du §11. Le mot de passe va dans le trousseau, jamais
    /// dans le fichier de configuration, et Latch l'écrit sur le pseudo-terminal
    /// après avoir vu l'invite — jamais sur une ligne de commande.
    @ViewBuilder
    private func passwordFallback(alias: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.latchBorder).padding(.vertical, 2)

            Text.paragraph(hasStoredPassword
                ? "Un mot de passe est enregistré dans le trousseau pour cet hôte."
                : "Si cet hôte n'accepte décidément que les mots de passe, "
                    + "Latch peut en garder un dans le trousseau du système.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.latchTextFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField("Mot de passe", text: $storedPassword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.latchBackground))

                Button(hasStoredPassword ? "Remplacer" : "Enregistrer") {
                    savePassword(for: alias)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(storedPassword.isEmpty)

                if hasStoredPassword {
                    Button("Oublier") {
                        Keychain.remove(alias: alias, account: SSHConfig.user(for: alias))
                        hasStoredPassword = false
                        passwordError = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchAccent)
                }
            }

            if let passwordError {
                Text(passwordError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.latchAccent)
            }
        }
    }

    private func savePassword(for alias: String) {
        do {
            try Keychain.store(
                storedPassword, alias: alias, account: SSHConfig.user(for: alias)
            )
            storedPassword = ""
            hasStoredPassword = true
            passwordError = nil
        } catch {
            passwordError = error.localizedDescription
        }
    }

    // MARK: Hooks Claude Code (§10)

    /// Rien n'est installé en silence, et ce qui sera exécuté est montré en
    /// clair avant de l'être — le script complet est dépliable.
    private var hooksBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Hooks Latch", systemImage: "bolt.horizontal")
                    .labelStyle(SectionLabelStyle())
                // Savoir avant d'appuyer : un bouton « Installer » qui répond
                // « rien à changer » donne l'impression de n'avoir rien fait.
                if hooksInstalled == true {
                    Text("en place")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.latchSuccess)
                }
            }

            Text.paragraph("Ils font remonter l'activité de Claude Code : l'indicateur, "
                + "le fichier en cours, et une notification quand une "
                + "permission est attendue.")
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextDim)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $showsHookScript) {
                CommandBox(command: HookInstaller.hookScript)
                    .padding(.top, 6)
            } label: {
                Text("Voir le script installé sur le serveur")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchAccent)
            }

            Text.paragraph("Les hooks existants de ~/.claude/settings.json sont "
                + "conservés, et une copie est mise de côté avant modification.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.latchTextFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                // Contrairement aux paquets du §6, ça n'écrit que dans le
                // dossier personnel : pas de sudo, donc l'app peut le faire
                // elle-même — après confirmation explicite, comme le veut le §10.
                Button(hookButtonTitle) {
                    confirmsHookInstall = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.latchClaude)
                .controlSize(.small)
                .disabled(isInstallingHooks)

                Button("Copier la commande") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HookInstaller.installCommand, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .font(.system(size: 11))
            .confirmationDialog(
                target.alias.map { String(format: localized("Installer les hooks sur %@ ?"), $0) }
                    ?? localized("Installer les hooks sur ce Mac ?"),
                isPresented: $confirmsHookInstall,
                titleVisibility: .visible
            ) {
                Button("Installer") { installHooks() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text.paragraph("Latch écrira ~/.latch/hook.sh et ajoutera ses entrées à "
                    + "~/.claude/settings.json, dont une copie sera mise de côté. "
                    + "Rien d'autre n'est touché, et aucun sudo n'est demandé.")
            }

            if let hookInstallResult {
                Text(hookInstallResult)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.latchTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(HookInstaller.uninstallHint)
                .font(.system(size: 10))
                .foregroundStyle(Color.latchTextFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hookButtonTitle: String {
        if isInstallingHooks { return "Installation…" }
        return hooksInstalled == true ? "Réinstaller" : "Installer"
    }

    private func installHooks() {
        isInstallingHooks = true
        hookInstallResult = nil
        Task {
            switch await app.installHooks(on: target.alias ?? "") {
            case .success(let output):
                hookInstallResult = output.isEmpty ? "latch: hooks installés." : output
                hooksInstalled = true
            case .failure(let error):
                hookInstallResult = error.localizedDescription
            }
            isInstallingHooks = false
        }
    }

    // MARK: Serveur MCP (§10)

    /// Claude Code tourne sur le serveur, Latch ici. Le pont est le `-R` que
    /// porte déjà la connexion des hooks : le serveur atteint Latch sur son
    /// propre localhost, et rien n'est exposé au réseau.
    @ViewBuilder
    private var mcpBlock: some View {
        if app.mcp.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                Label("Piloter Latch depuis Claude Code", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(SectionLabelStyle())

                Group {
                    if let alias = target.alias {
                        Text(
                            String(
                                format: localized("À lancer une fois sur %@, pendant qu'une session Latch y est ouverte — c'est elle qui porte le tunnel. Claude Code pourra alors ouvrir un onglet, lancer une commande ou afficher un fichier."),
                                alias
                            )
                        )
                    } else {
                        Text.paragraph("À lancer une fois dans un terminal de ce Mac. Pas de "
                            + "tunnel ici : le serveur est déjà à cette adresse. Claude Code "
                            + "pourra alors ouvrir un onglet, lancer une commande ou afficher "
                            + "un fichier.")
                    }
                }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextDim)
                    .fixedSize(horizontal: false, vertical: true)

                CommandBox(command: app.mcp.claudeRegistrationCommand)
                actions(for: app.mcp.claudeRegistrationCommand)

                Text.paragraph("Le jeton est tiré à chaque lancement de Latch : relancer "
                    + "l'app invalide l'accès précédent, et cette commande est "
                    + "à rejouer.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.latchTextFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Côté Mac

    /// Le §6 ne parle que du serveur, mais mosh a besoin des deux bouts. Une
    /// compilation locale de Latch n'embarque pas `mosh-client` : autant le
    /// dire ici plutôt que de laisser une connexion échouer sans raison
    /// apparente.
    @ViewBuilder
    private var localMoshBlock: some View {
        if case .absent = MoshClient.locate() {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sur ce Mac", systemImage: "laptopcomputer")
                    .labelStyle(SectionLabelStyle())

                Text(MoshClient.missingLocallyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextDim)
                    .fixedSize(horizontal: false, vertical: true)

                CommandBox(command: "brew install mosh")
                actions(for: "brew install mosh")
            }
        }
    }

    // MARK: Le piège du §6

    private var pathHint: some View {
        Text(ServerUpgradePlanner.nonInteractivePathHint)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.latchTextFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var skipToggle: some View {
        Toggle(isOn: skipBinding) {
            Text("Ne plus proposer pour cet hôte")
                .font(.system(size: 11))
                .foregroundStyle(Color.latchTextDim)
        }
        .toggleStyle(.checkbox)
    }

    private var skipBinding: Binding<Bool> {
        Binding(
            get: { server?.skipUpgradePrompt ?? false },
            set: { newValue in
                guard var updated = server else { return }
                updated.skipUpgradePrompt = newValue
                app.store.update(updated)
            }
        )
    }

    // MARK: Les deux boutons

    private func actions(for command: String) -> some View {
        HStack(spacing: 8) {
            // Action par défaut, et la plus sûre : rien n'est exécuté.
            Button("Copier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.latchAccent)
            .controlSize(.small)

            Button("Exécuter dans un panneau") {
                runInPane(command)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.system(size: 11))
    }

    /// Ouvre un onglet sur cet hôte et y **écrit** la commande, sans l'exécuter :
    /// le curseur reste en fin de ligne. L'utilisateur appuie lui-même sur
    /// Entrée et tape son mot de passe sudo dans un vrai TTY.
    private func runInPane(_ command: String) {
        let session = target.alias.map {
            app.openBareShell(on: $0, named: "installer · \(target.name)")
        } ?? app.openLocalShell(named: "installer · \(target.name)")
        Task {
            // On attend que le shell distant ait rendu la main. Il n'y a pas de
            // signal fiable pour ça sans analyser l'invite : une temporisation
            // courte, et l'utilisateur voit de toute façon ce qui se passe.
            try? await Task.sleep(for: .milliseconds(1200))
            session.type(command)
        }
    }

    /// À la fermeture, on invalide la sonde et on la relance : le bandeau
    /// disparaît tout seul si l'installation a réussi, et reste sinon. Pas de
    /// confirmation de succès qu'on n'aurait pas vérifiée.
    private func close() {
        let server = self.server
        app.upgradingTarget = nil
        // Les deux sondes sont en cache : on les rafraîchit pour que le
        // bandeau disparaisse tout seul si l'installation a réussi, et reste
        // sinon. Pas de confirmation de succès qu'on n'aurait pas vérifiée.
        guard let server else { return app.refreshLocalProbe() }
        Task {
            app.store.invalidateProbe(serverID: server.id)
            await app.store.probe(serverID: server.id, force: true)
        }
    }
}

// MARK: - Petits éléments

private struct SectionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 10))
            configuration.title
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.latchTextDim)
    }
}

/// Mono, sélectionnable — on doit pouvoir la lire et la copier à la main.
private struct CommandBox: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Color.latchText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.latchBackground))
    }
}

// MARK: - Bandeau

/// Le bandeau non bloquant du §6 : cliquable, il ouvre le panneau.
struct DegradationBanner: View {
    @EnvironmentObject private var app: AppState
    let degradation: Degradation
    let target: UpgradeTarget?

    var body: some View {
        Button {
            app.upgradingTarget = target
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text(degradation.bannerTitle)
                    .font(.system(size: 11))
                Text(degradation.consequence)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.latchTextDim)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if target != nil {
                    Text("Améliorer…")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(Color.latchAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color.latchSurface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
