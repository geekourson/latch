//
//  PasswordPrompt.swift
//  Latch
//
//  SPEC §11 : le mot de passe s'écrit **sur le PTY**, après détection du
//  prompt, jamais en argument de commande. Plusieurs motifs, et un délai
//  d'attente.
//
//  Trois garde-fous, parce qu'un automate qui tape un mot de passe tout seul
//  est une mauvaise idée dès qu'il se trompe de moment :
//
//    — une fenêtre de temps après la connexion, au-delà de laquelle plus rien
//      n'est envoyé : passé ce délai, c'est l'utilisateur qui tape, et un
//      « password: » dans un `git push` ne le concerne pas ;
//    — un plafond de tentatives, pour ne pas rejouer un mot de passe refusé
//      jusqu'au verrouillage du compte ;
//    — un intervalle minimal, pour ne pas répondre deux fois à la même invite
//      redessinée.
//

import Foundation

struct PasswordPromptDetector {

    /// Les mots qui trahissent une demande de secret, en minuscules. ssh se dit
    /// en anglais comme dans la langue du système : les deux sont là.
    ///
    /// Ce sont bien des mots-clés et non des fins de ligne : l'invite de phrase
    /// de passe est `Enter passphrase for key '/…/id_ed25519': `, où le motif
    /// est au début et le chemin à la fin.
    static let patterns = [
        "password",
        "mot de passe",
        "passphrase",
        "phrase secrète",
    ]

    /// Une invite tient sur une ligne courte. Au-delà, c'est de la sortie de
    /// programme qui parle de mots de passe, pas une question posée.
    static let maximumPromptLength = 160

    /// Combien de temps après le lancement on accepte de répondre.
    var window: TimeInterval = 45
    /// Au-delà, on arrête : un mot de passe refusé trois fois verrouille des
    /// comptes, et le rejouer ne le rendra pas meilleur.
    var maximumAttempts = 3
    /// Une même invite redessinée ne doit pas déclencher deux réponses.
    var minimumInterval: TimeInterval = 1.5

    private(set) var attempts = 0
    private var lastAnswer: Date?
    private var tail = ""

    /// La fin du flux suffit à reconnaître une invite, et borner ce qu'on garde
    /// évite de faire grossir un tampon indéfiniment.
    private static let tailLength = 200

    /// Note les octets reçus et dit s'il faut répondre maintenant.
    ///
    /// - Parameters:
    ///   - text: le fragment reçu.
    ///   - elapsed: temps écoulé depuis le lancement de la commande.
    ///   - now: l'instant courant, injectable pour les tests.
    mutating func shouldAnswer(
        after text: String, elapsed: TimeInterval, now: Date = Date()
    ) -> Bool {
        tail = String((tail + text.lowercased()).suffix(Self.tailLength))

        guard elapsed <= window, attempts < maximumAttempts else { return false }
        if let lastAnswer, now.timeIntervalSince(lastAnswer) < minimumInterval { return false }

        // Une question se termine par deux points, et le curseur attend juste
        // derrière : c'est ce qui distingue une invite d'une ligne de sortie
        // qui parle de mots de passe.
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(":") else { return false }

        let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
        guard lastLine.count <= Self.maximumPromptLength,
              Self.patterns.contains(where: { lastLine.contains($0) })
        else { return false }

        attempts += 1
        lastAnswer = now
        // Le motif est consommé : la même invite ne doit pas rester en fin de
        // tampon et redéclencher au fragment suivant.
        tail = ""
        return true
    }

    /// Remet le compteur à zéro — après une reconnexion réussie, par exemple.
    mutating func reset() {
        attempts = 0
        lastAnswer = nil
        tail = ""
    }
}
