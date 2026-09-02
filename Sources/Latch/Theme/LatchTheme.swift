//
//  LatchTheme.swift
//  Latch
//
//  Palette « braise » (SPEC §9.3) : charbon chaud plutôt que gris neutre.
//  L'import de thèmes base16 / iTerm2 est prévu pour la v0.2 ; d'ici là cette
//  palette est la seule, et elle est codée une fois, ici.
//

import AppKit
import SwiftTerm
import SwiftUI

enum LatchTheme {

    // MARK: - Palette

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
    /// SF Mono, sinon Menlo — qui, elle, est toujours là.
    static func monoFont(size: CGFloat = 13) -> NSFont {
        for name in ["JetBrainsMono-Regular", "JetBrains Mono", "SFMono-Regular"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Couleurs ANSI

    /// Les 16 couleurs ANSI, dans l'ordre attendu par SwiftTerm :
    /// noir, rouge, vert, jaune, bleu, magenta, cyan, blanc, puis les vives.
    static let ansiColors: [SwiftTerm.Color] = [
        0x241D18, 0xC96A5E, 0x8FB09A, 0xC89B6A,
        0x7E9CC0, 0xB3A0D6, 0x86B4B0, 0xEDE4D8,
        0x57493F, 0xDE8579, 0xA9C7B3, 0xDDB688,
        0x9AB5D6, 0xC9B9E6, 0xA1CCC8, 0xFFFFFF,
    ].map { SwiftTerm.Color(hex: $0) }
}

// MARK: - Confort

extension NSColor {
    /// `0xRRGGBB`, dans l'espace sRGB — pas dans l'espace « device » dont le
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

extension SwiftTerm.Color {
    convenience init(hex: UInt32) {
        self.init(
            red8: UInt16((hex >> 16) & 0xFF),
            green8: UInt16((hex >> 8) & 0xFF),
            blue8: UInt16(hex & 0xFF)
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
}
