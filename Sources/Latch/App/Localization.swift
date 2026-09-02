//
//  Localization.swift
//  Latch
//
//  Latch est écrite en français, et le français est donc la langue de
//  développement : les littéraux du code servent de clés. L'anglais vit dans
//  `en.lproj/Localizable.strings`.
//
//  SwiftUI localise `Text("…")` tout seul, mais toujours depuis `Bundle.main`,
//  dont la langue est fixée au lancement par le système. Pour laisser le choix
//  à l'utilisateur, on remplace la classe de `Bundle.main` par une sous-classe
//  qui consulte le paquet de langue voulu. C'est le seul point d'entrée que
//  SwiftUI, AppKit et `String(localized:)` partagent tous les trois.
//

import Foundation
import SwiftUI

enum Language: String, Codable, CaseIterable, Identifiable {
    /// Celle du système, quelle qu'elle soit.
    case system
    case french = "fr"
    case english = "en"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "Langue du système")
        case .french: return "Français"
        case .english: return "English"
        }
    }

    /// Le code de langue à utiliser réellement.
    var resolved: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "fr"
            return preferred.hasPrefix("fr") ? "fr" : "en"
        case .french, .english:
            return rawValue
        }
    }
}

enum Localization {

    /// Applique la langue à `Bundle.main`. Idempotent.
    static func apply(_ language: Language) {
        activate(language.resolved)
    }

    private static var isPrepared = false

    private static func activate(_ code: String) {
        if !isPrepared {
            // On ne remplace la classe qu'une fois : la sous-classe lit ensuite
            // une variable, ce qui suffit à changer de langue à chaud.
            object_setClass(Bundle.main, LocalizedBundle.self)
            isPrepared = true
        }
        LocalizedBundle.path =
            Bundle.main.path(forResource: code, ofType: "lproj")
            ?? Bundle.main.path(forResource: "fr", ofType: "lproj")
    }
}

/// Un `Bundle` qui va chercher ses chaînes dans le paquet de langue choisi.
private final class LocalizedBundle: Bundle, @unchecked Sendable {

    nonisolated(unsafe) static var path: String?

    override func localizedString(
        forKey key: String, value: String?, table tableName: String?
    ) -> String {
        guard let path = Self.path, let bundle = Bundle(path: path) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

/// Traduit une chaîne construite à l'exécution.
///
/// SwiftUI ne localise que les **littéraux** : `Text("a" + "b")` reçoit un
/// `String` déjà assemblé et passe tout droit. Les textes longs de Latch sont
/// écrits en concaténations pour tenir dans la largeur du fichier, d'où ce
/// passage explicite. La clé reste la phrase française complète.
func localized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

extension Text {
    /// Un paragraphe écrit en concaténation : traduit, puis relu comme du
    /// Markdown pour que les mises en gras survivent à la traduction.
    static func paragraph(_ text: String) -> Text {
        Text(.init(localized(text)))
    }
}
