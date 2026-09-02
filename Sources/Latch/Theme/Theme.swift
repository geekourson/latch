//
//  Theme.swift
//  Latch
//
//  SPEC §9.3 : « prévoir l'import de thèmes au format base16 ou iTerm2 — ne pas
//  inventer un format maison ». Latch ne définit donc aucun format d'échange :
//  elle lit les deux formats existants et garde le résultat dans sa
//  configuration, au même titre que le reste des réglages.
//

import AppKit
import Foundation
import SwiftTerm

// MARK: - Couleur

/// Une couleur sRGB, écrite `RRGGBB` — lisible dans le fichier de config et
/// suffisante pour un terminal.
struct ThemeColor: Codable, Equatable, Hashable {
    var hex: String

    init(hex: String) {
        self.hex = ThemeColor.normalise(hex)
    }

    init(red: Double, green: Double, blue: Double) {
        func component(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        self.hex = String(
            format: "%02X%02X%02X", component(red), component(green), component(blue)
        )
    }

    init(_ value: UInt32) {
        self.hex = String(format: "%06X", value & 0xFF_FFFF)
    }

    /// Accepte `#rgb`, `#rrggbb`, `rrggbb`, avec ou sans dièse.
    private static func normalise(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        text = text.replacingOccurrences(of: "#", with: "")
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return "000000" }
        return text
    }

    var value: UInt32 { UInt32(hex, radix: 16) ?? 0 }

    var nsColor: NSColor { NSColor(hex: value) }

    var cgColor: CGColor { nsColor.cgColor }

    var terminalColor: SwiftTerm.Color { SwiftTerm.Color(hex: value) }
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

// MARK: - Thème

struct Theme: Codable, Identifiable, Equatable {

    enum Source: String, Codable {
        case builtIn, iTerm2, base16

        var label: String {
            switch self {
            case .builtIn: return "intégré"
            case .iTerm2: return "iTerm2"
            case .base16: return "base16"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var source: Source = .builtIn

    var background: ThemeColor
    var foreground: ThemeColor
    var cursor: ThemeColor
    var selectionBackground: ThemeColor
    var selectionForeground: ThemeColor?

    /// Les seize couleurs ANSI, dans l'ordre attendu par SwiftTerm : noir,
    /// rouge, vert, jaune, bleu, magenta, cyan, blanc, puis les vives.
    var ansi: [ThemeColor]

    var isValid: Bool { ansi.count == 16 }

    var terminalColors: [SwiftTerm.Color] { ansi.map(\.terminalColor) }
}

// MARK: - Le thème par défaut

extension Theme {

    /// La palette « braise » du §9.3 : charbon chaud plutôt que gris neutre.
    static let ember = Theme(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!,
        name: "Braise",
        source: .builtIn,
        background: ThemeColor(0x17130F),
        foreground: ThemeColor(0xEDE4D8),
        cursor: ThemeColor(0xC89B6A),
        selectionBackground: ThemeColor(0x241D18),
        selectionForeground: nil,
        ansi: [
            0x241D18, 0xC96A5E, 0x8FB09A, 0xC89B6A,
            0x7E9CC0, 0xB3A0D6, 0x86B4B0, 0xEDE4D8,
            0x57493F, 0xDE8579, 0xA9C7B3, 0xDDB688,
            0x9AB5D6, 0xC9B9E6, 0xA1CCC8, 0xFFFFFF,
        ].map(ThemeColor.init)
    )
}
