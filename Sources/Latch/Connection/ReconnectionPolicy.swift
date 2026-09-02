//
//  ReconnectionPolicy.swift
//  Latch
//
//  Le §8 tient en trois règles :
//
//    — au réveil, si le process est vivant (le cas normal avec mosh), ne rien
//      faire. S'il est mort, relancer **exactement la même commande** : `-A`
//      s'occupe du reste ;
//    — backoff exponentiel plafonné à 30 s ;
//    — jamais de reconnexion silencieuse en boucle sur un échec
//      d'authentification. Après trois échecs, on s'arrête et on attend.
//

import Foundation

struct ReconnectionPolicy: Equatable {

    /// Délai avant la première nouvelle tentative.
    var base: TimeInterval = 1
    /// Plafond du backoff.
    var cap: TimeInterval = 30
    /// Au-delà, on passe en `.failed` et on attend une action.
    var maxAttempts: Int = 3
    /// Une connexion qui meurt avant ce délai n'a pas vraiment abouti : c'est
    /// une authentification refusée, un hôte injoignable, un `mosh-server`
    /// absent. La compter comme un échec, pas comme une déconnexion.
    var minimumLifetime: TimeInterval = 5

    /// Délai avant la tentative `attempt` (1 pour la première).
    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // `min` avant `pow` protège du dépassement sur un compteur qui aurait
        // dérivé : 2^100 secondes n'a pas de sens, 30 non plus mais au moins
        // c'est le plafond demandé.
        let exponent = min(attempt - 1, 16)
        return min(base * pow(2, Double(exponent)), cap)
    }

    /// Faut-il retenter après cette tentative ?
    func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    /// Une connexion qui n'a pas tenu assez longtemps n'a jamais abouti.
    func countsAsFailure(lifetime: TimeInterval) -> Bool {
        lifetime < minimumLifetime
    }

    /// Le message affiché quand on renonce.
    func giveUpReason(lastExitCode: Int32?) -> String {
        var reason = "Trois tentatives de reconnexion ont échoué."
        if let lastExitCode, lastExitCode == 255 {
            reason += " ssh a rendu 255 : hôte injoignable ou authentification "
                + "refusée. Latch ne réessaiera pas tout seul."
        } else {
            reason += " Latch ne réessaiera pas tout seul."
        }
        return reason
    }
}
