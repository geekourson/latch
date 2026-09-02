//
//  LatchTheme.swift
//  Latch
//
//  La palette « braise » du §9.3 habille l'application elle-même — barre
//  latérale, onglets, panneaux. Le terminal, lui, suit le thème choisi : un
//  thème iTerm2 clair importé pour lire du code ne doit pas repeindre toute
//  l'app au passage.
//

import AppKit
import SwiftUI

enum LatchTheme {

    // MARK: - Chrome de l'application

    static let background = NSColor(hex: 0x17130F)
    static let surface = NSColor(hex: 0x1D1813)
    static let surfaceHigh = NSColor(hex: 0x241D18)
    static let border = NSColor(hex: 0x2A231D)
    static let borderStrong = NSColor(hex: 0x3A302A)
    static let text = NSColor(hex: 0xEDE4D8)
    static let textDim = NSColor(hex: 0x7C6F63)
    static let textFaint = NSColor(hex: 0x57493F)
    static let accent = NSColor(hex: 0xC89B6A)   // ambre
    static let success = NSColor(hex: 0x8FB09A)  // sauge
    static let claude = NSColor(hex: 0xB3A0D6)   // violet Claude Code

    // MARK: - Typographie

    /// Police mono du terminal. JetBrains Mono si elle est installée, sinon
    /// SF Mono, sinon la mono du système — qui, elle, est toujours là.
    static func monoFont(named name: String? = nil, size: CGFloat = 13) -> NSFont {
        var candidates: [String] = []
        if let name, !name.isEmpty { candidates.append(name) }
        candidates += ["JetBrainsMono-Regular", "JetBrains Mono", "SFMono-Regular"]

        for candidate in candidates {
            if let font = NSFont(name: candidate, size: size) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Les familles à largeur fixe installées, pour le sélecteur des réglages.
    static var availableMonoFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        .sorted()
    }
}

// MARK: - Style du terminal

/// Ce qu'il faut savoir pour habiller une vue de terminal : un thème et une
/// typographie. Une valeur, comparable, pour que la vue ne se réapplique que
/// quand quelque chose a vraiment changé.
struct TerminalStyle: Equatable {
    var theme: Theme = .ember
    var fontName: String?
    var fontSize: CGFloat = 13
    /// Multiplicateur de la hauteur de ligne (SPEC §9.1).
    var lineSpacing: CGFloat = 1.25
    /// Marges autour du terminal (SPEC §9.1 : 18–22 px).
    var padding: CGFloat = 20

    var font: NSFont { LatchTheme.monoFont(named: fontName, size: fontSize) }
}

// MARK: - Confort

extension NSColor {
    /// `0xRRGGBB`, dans l'espace sRGB — pas dans l'espace « device », dont le
    /// rendu dépend de l'écran.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension SwiftUI.Color {
    static let latchBackground = SwiftUI.Color(LatchTheme.background)
    static let latchSurface = SwiftUI.Color(LatchTheme.surface)
    static let latchSurfaceHigh = SwiftUI.Color(LatchTheme.surfaceHigh)
    static let latchBorder = SwiftUI.Color(LatchTheme.border)
    static let latchText = SwiftUI.Color(LatchTheme.text)
    static let latchTextDim = SwiftUI.Color(LatchTheme.textDim)
    static let latchTextFaint = SwiftUI.Color(LatchTheme.textFaint)
    static let latchAccent = SwiftUI.Color(LatchTheme.accent)
    static let latchSuccess = SwiftUI.Color(LatchTheme.success)
    static let latchClaude = SwiftUI.Color(LatchTheme.claude)
}
