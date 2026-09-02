//
//  CommandBuilder.swift
//  Latch
//
//  Le cœur du projet (SPEC §3.3, §5) : une fonction pure qui transforme un
//  `Shortcut` en une seule chaîne, exécutée localement par `/bin/sh -c`.
//
//  Règle générale :
//
//      <pré-vol> && <transport> <préfixe tmux> '<commande initiale>'
//
//  `tmux new -A -s <session>` attache si la session existe et la crée sinon :
//  aucune logique conditionnelle « la session existe-t-elle ? » nulle part.
//

import Foundation

// MARK: - Validation

struct ValidationIssue: Identifiable, Equatable {
    enum Field: Equatable {
        case host, jumpHost, tmuxSession, workingDirectory
        case controlMode, extraArgs, initialCommand, window, preflight
    }

    var id: String { "\(field)-\(message)" }
    var field: Field
    var message: String
}

enum CommandBuilderError: LocalizedError, Equatable {
    case invalid([ValidationIssue])

    var errorDescription: String? {
        guard case .invalid(let issues) = self else { return nil }
        return issues.map(\.message).joined(separator: "\n")
    }
}

// MARK: - Construction

enum CommandBuilder {

    /// La commande complète, pré-vol compris.
    ///
    /// Un raccourci mal formé n'est jamais exécuté : on préfère une erreur de
    /// validation à une commande approximative.
    static func build(_ shortcut: Shortcut, degradation: Degradation = .none) throws -> String {
        if let custom = shortcut.customCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }

        let issues = validate(shortcut)
        guard issues.isEmpty else { throw CommandBuilderError.invalid(issues) }

        let connection = try connectionCommand(shortcut, degradation: degradation)
        let steps = shortcut.preflight.map(preflightCommand) + [connection]
        return steps.joined(separator: " && ")
    }

    /// La commande de connexion seule, sans le pré-vol.
    ///
    /// `degradation` vient de la sonde du §6 et n'est jamais persistée : la
    /// connexion réussit toujours, quitte à perdre mosh ou tmux en route.
    static func connectionCommand(
        _ shortcut: Shortcut,
        degradation: Degradation = .none
    ) throws -> String {
        let issues = validate(shortcut)
        guard issues.isEmpty else { throw CommandBuilderError.invalid(issues) }

        var connection = shortcut.connection

        // Cascade du §6. Sans mosh-server en face, mosh ne peut pas s'établir :
        // on bascule sur ssh plutôt que d'échouer.
        if degradation != .none, connection.transport == .mosh {
            connection.transport = .ssh
        }
        // Sans tmux, il ne reste qu'un shell nu — et un bandeau pour prévenir
        // que la session ne survivra pas à la fermeture de l'onglet.
        if degradation == .tmuxMissing {
            return bareShellCommand(connection)
        }

        let remote = tmuxInvocation(connection, windows: shortcut.windows)
        let host = ShellQuoting.quoted(connection.host)

        switch connection.transport {
        case .local:
            // Exécutée par le `/bin/sh -c` local : le tilde y est développé.
            return remote

        case .ssh:
            // `-t` est indispensable : sans allocation de TTY, tmux refuse de
            // démarrer. La commande distante passe par le shell de connexion,
            // qui développe `~` et `$SHELL`.
            return "ssh -t \(host) \(ShellQuoting.doubleQuoted(remote))"

        case .sshJump:
            let jump = ShellQuoting.quoted(connection.jumpHost ?? "")
            return "ssh -t -J \(jump) \(host) \(ShellQuoting.doubleQuoted(remote))"

        case .eternalTerminal:
            return "et \(host) -c \(ShellQuoting.doubleQuoted(remote))"

        case .mosh:
            // mosh sépare ses arguments de la commande distante par `--`, et
            // exécute cette commande **directement**, sans shell. Un chemin
            // qui demande à être développé (`~`, `$`) n'a donc personne pour
            // le faire de l'autre côté — et le shell local, lui, le
            // développerait avec *son* répertoire personnel. D'où le `sh -c`
            // explicite dans ce cas, et seulement dans ce cas.
            if needsRemoteShell(connection) {
                return "mosh \(host) -- sh -c \(ShellQuoting.doubleQuoted(remote))"
            }
            return "mosh \(host) -- \(remote)"
        }
    }

    /// Dernier étage de la cascade : l'hôte n'a pas tmux, on ouvre un shell nu.
    /// Rien d'autre — pas de commande initiale, pas de fenêtres : sans tmux il
    /// n'y a ni session à retrouver ni fenêtre à créer, et prétendre le
    /// contraire ne ferait qu'égarer l'utilisateur.
    static func bareShellCommand(_ connection: Connection) -> String {
        let host = ShellQuoting.quoted(connection.host)
        switch connection.transport {
        case .local:
            return "exec $SHELL"
        case .eternalTerminal:
            return "et \(host)"
        case .sshJump:
            return "ssh -t -J \(ShellQuoting.quoted(connection.jumpHost ?? "")) \(host)"
        case .ssh, .mosh:
            return "ssh -t \(host)"
        }
    }

    // MARK: Préfixe tmux

    /// `tmux [-CC] new -A -s <session> [-c <dir>] ['<commande>']`
    static func tmuxInvocation(_ connection: Connection, windows: [TmuxWindow]) -> String {
        var parts = ["tmux"]
        if connection.controlMode { parts.append("-CC") }
        parts += ["new", "-A", "-s", ShellQuoting.quoted(connection.tmuxSession)]

        if let directory = connection.workingDirectory?.trimmingCharacters(in: .whitespaces),
           !directory.isEmpty {
            parts += ["-c", ShellQuoting.remotePath(directory)]
        }

        if let command = sessionCommand(connection, windows: windows) {
            parts.append(ShellQuoting.singleQuoted(command))
        }
        return parts.joined(separator: " ")
    }

    /// Ce que tmux lance dans la fenêtre 0, **à la création seulement**. Aux
    /// lancements suivants, `-A` attache et l'ignore : c'est voulu.
    ///
    /// Les fenêtres supplémentaires sont créées d'ici, et non enchaînées après
    /// un `\;` sur la ligne tmux : une commande chaînée rejoue à chaque
    /// réattache et empilerait un doublon de chaque fenêtre à chaque connexion.
    static func sessionCommand(_ connection: Connection, windows: [TmuxWindow]) -> String? {
        var pieces: [String] = windows.map { window in
            "tmux new-window -d -n \(ShellQuoting.quoted(window.name)) "
                + ShellQuoting.singleQuoted(window.command)
        }

        let initial = connection.initialCommand.executable
        if var command = initial {
            if let extra = connection.extraArgs?.trimmingCharacters(in: .whitespaces),
               !extra.isEmpty {
                command += " " + extra
            }
            pieces.append(command)
        }

        guard !pieces.isEmpty else { return nil }

        // `exec $SHELL` garde la session en vie après la sortie de la commande
        // initiale. Sans commande initiale, il n'est pas optionnel : on vient
        // de remplacer le shell par défaut de la fenêtre 0 par la création des
        // fenêtres, il faut le rendre.
        if connection.keepShellOnExit || initial == nil {
            pieces.append("exec $SHELL")
        }
        return pieces.joined(separator: "; ")
    }

    // MARK: Pré-vol

    /// Un pré-vol fatal coupe la chaîne `&&`. Un pré-vol non fatal est enfermé
    /// dans un groupe qui réussit toujours, pour avertir sans rien empêcher.
    private static func preflightCommand(_ preflight: Preflight) -> String {
        let command = preflight.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if preflight.failureIsFatal { return command }

        let warning = ShellQuoting.singleQuoted(
            "Latch : le pré-vol « \(preflight.label) » a échoué — on continue."
        )
        return "{ \(command) || echo \(warning) >&2; }"
    }

    private static func needsRemoteShell(_ connection: Connection) -> Bool {
        guard let directory = connection.workingDirectory, !directory.isEmpty else { return false }
        return ShellQuoting.needsShellExpansion(directory)
    }

    // MARK: - Validation

    static func validate(_ shortcut: Shortcut) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let connection = shortcut.connection

        if connection.transport.isRemote,
           connection.host.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(field: .host, message: "Il manque l'hôte."))
        }

        let jump = connection.jumpHost?.trimmingCharacters(in: .whitespaces) ?? ""
        if connection.transport == .sshJump, jump.isEmpty {
            issues.append(.init(field: .jumpHost, message: "Il manque l'hôte de rebond."))
        }
        if connection.transport != .sshJump, !jump.isEmpty {
            issues.append(.init(
                field: .jumpHost,
                message: "Un hôte de rebond n'a de sens qu'avec le transport « ssh via rebond »."
            ))
        }

        let session = connection.tmuxSession.trimmingCharacters(in: .whitespaces)
        if session.isEmpty {
            issues.append(.init(field: .tmuxSession, message: "Il manque le nom de session tmux."))
        } else if session.contains(":") || session.contains(".") {
            issues.append(.init(
                field: .tmuxSession,
                message: "tmux refuse « : » et « . » dans un nom de session."
            ))
        }

        // Refusé au niveau du modèle, avec un message clair, plutôt qu'autorisé
        // puis échouant à l'exécution (SPEC §5).
        if connection.controlMode, connection.transport == .mosh {
            issues.append(.init(
                field: .controlMode,
                message: "Le mode contrôle (tmux -CC) est incompatible avec mosh. "
                    + "Choisis ssh, ou décoche le mode contrôle."
            ))
        }

        let extra = connection.extraArgs?.trimmingCharacters(in: .whitespaces) ?? ""
        if !extra.isEmpty, connection.initialCommand.executable == nil {
            issues.append(.init(
                field: .extraArgs,
                message: "Des arguments supplémentaires sans commande initiale à qui les passer."
            ))
        }

        if case .custom(let command) = connection.initialCommand,
           command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .initialCommand, message: "La commande personnalisée est vide."))
        }

        for window in shortcut.windows {
            if window.name.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.init(field: .window, message: "Une fenêtre tmux n'a pas de nom."))
            }
            if window.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    field: .window,
                    message: "La fenêtre « \(window.name) » n'a pas de commande."
                ))
            }
        }

        for preflight in shortcut.preflight
        where preflight.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                field: .preflight,
                message: "Le pré-vol « \(preflight.label) » n'a pas de commande."
            ))
        }

        return issues
    }
}
