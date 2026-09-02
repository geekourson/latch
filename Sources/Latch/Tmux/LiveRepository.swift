//
//  LiveRepository.swift
//  Latch
//
//  SPEC §9.1 : la barre d'état basse montre « état Claude Code, branche git,
//  diff, latence ».
//
//  Le dépôt est celui du **panneau actif de la session distante**, pas celui du
//  Mac : c'est là que le travail se fait. tmux sait où en est chaque panneau,
//  la connexion secondaire demande le reste au même moment que les fenêtres.
//

import Foundation

/// Ce que git dit d'un répertoire, à l'instant où on l'a demandé.
struct LiveRepository: Equatable {
    var session: String
    var branch: String
    var insertions: Int = 0
    var deletions: Int = 0

    var isDirty: Bool { insertions > 0 || deletions > 0 }

    /// « main +12 −3 », ou « main » quand rien n'a bougé.
    var summary: String {
        guard isDirty else { return branch }
        var parts = [branch]
        if insertions > 0 { parts.append("+\(insertions)") }
        if deletions > 0 { parts.append("−\(deletions)") }
        return parts.joined(separator: " ")
    }

    /// Analyse une ligne `LATCH_GIT<sep>session<sep>branche<sep>shortstat`.
    ///
    /// `git diff --shortstat` rend une phrase en anglais dont on ne garde que
    /// les nombres : « 3 files changed, 12 insertions(+), 3 deletions(-) ».
    static func parse(fields: [String]) -> LiveRepository? {
        guard fields.count >= 3 else { return nil }
        let branch = fields[1].trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return nil }

        var repository = LiveRepository(session: fields[0], branch: branch)
        let shortstat = fields.count > 2 ? fields[2] : ""
        repository.insertions = number(before: "insertion", in: shortstat)
        repository.deletions = number(before: "deletion", in: shortstat)
        return repository
    }

    private static func number(before keyword: String, in text: String) -> Int {
        // « 12 insertions(+) » : le nombre est le mot juste avant le mot-clé.
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        for (index, word) in words.enumerated() where word.hasPrefix(keyword) {
            guard index > 0 else { return 0 }
            return Int(words[index - 1]) ?? 0
        }
        return 0
    }
}
