//
//  Preferences.swift
//  Latch
//
//  Les réglages d'apparence du §9.3. Ils vivent dans le même fichier que les
//  raccourcis : il n'y a pas de raison d'en avoir deux.
//

import Foundation

struct Preferences: Codable, Equatable {
    /// Nom de famille de la police mono. `nil` laisse la cascade par défaut :
    /// JetBrains Mono, puis SF Mono, puis la mono du système.
    var fontName: String?
    var fontSize: Double = 13
    /// Multiplicateur de la hauteur de ligne (§9.1).
    var lineSpacing: Double = 1.25
    /// Marges autour du terminal (§9.1 : 18 à 22 px).
    var padding: Double = 20
    /// Thème importé actif. `nil` = la palette « braise » intégrée.
    var themeID: UUID?
    /// Langue de l'interface. Par défaut celle du système.
    var language: Language = .system
}
