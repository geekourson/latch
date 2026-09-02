//
//  PreviewEdit.swift
//  Latch
//
//  L'aperçu du §9.2 est éditable : le modifier bascule le raccourci en mode
//  personnalisé. Encore faut-il distinguer une frappe de l'utilisateur d'un
//  texte que l'app vient d'écrire elle-même.
//
//  Un drapeau posé et retiré autour de l'écriture ne suffit pas : la
//  notification de changement arrive au tour de boucle suivant, quand le
//  drapeau est déjà retombé. On compare donc au texte qu'on a écrit — ce qui
//  ne peut pas se tromper de moment.
//

import Foundation

enum PreviewEdit: Equatable {
    /// C'est l'app qui a écrit : ne rien en conclure.
    case ignore
    /// L'utilisateur a écrit une commande : le raccourci devient personnalisé.
    case adopt(String)
    /// Le champ a été vidé : retour au mode assisté.
    case revert

    static func decide(edited: String, lastGenerated: String) -> PreviewEdit {
        guard edited != lastGenerated else { return .ignore }

        let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .revert : .adopt(trimmed)
    }
}
