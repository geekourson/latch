//
//  ThemeImporter.swift
//  Latch
//
//  Lit les deux formats de thème qui existent déjà dans la nature : les
//  `.itermcolors` d'iTerm2 (une liste de propriétés) et les schémas base16
//  (du YAML volontairement simple). Latch n'en invente pas un troisième.
//

import Foundation

enum ThemeImporter {

    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let extensionName):
                return "Format de thème inconnu : « \(extensionName) ». "
                    + "Latch lit les fichiers .itermcolors et les schémas base16 (.yaml)."
            case .malformed(let detail):
                return "Thème illisible : \(detail)"
            }
        }
    }

    /// Devine le format d'après l'extension, puis délègue.
    static func theme(contentsOf url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent

        switch url.pathExtension.lowercased() {
        case "itermcolors", "plist":
            return try iTerm2Theme(from: data, fallbackName: name)
        case "yaml", "yml", "txt":
            return try base16Theme(
                from: String(decoding: data, as: UTF8.self), fallbackName: name
            )
        case let other:
            throw ImportError.unsupportedFormat(other)
        }
    }

    // MARK: - iTerm2

    /// Un `.itermcolors` est une liste de propriétés dont les clés sont
    /// `Ansi 0 Color` … `Ansi 15 Color`, `Background Color`, etc., chacune un
    /// dictionnaire de composantes flottantes entre 0 et 1.
    static func iTerm2Theme(from data: Data, fallbackName: String) throws -> Theme {
        guard
            let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
        else {
            throw ImportError.malformed("la liste de propriétés n'a pas pu être lue.")
        }

        func color(_ key: String) -> ThemeColor? {
            guard let entry = root[key] as? [String: Any] else { return nil }
            guard
                let red = entry["Red Component"] as? Double,
                let green = entry["Green Component"] as? Double,
                let blue = entry["Blue Component"] as? Double
            else { return nil }
            // Les composantes hors [0,1] viennent d'un espace large (P3) : on
            // les ramène dans sRGB plutôt que de refuser le fichier.
            return ThemeColor(red: red, green: green, blue: blue)
        }

        var ansi: [ThemeColor] = []
        for index in 0..<16 {
            guard let entry = color("Ansi \(index) Color") else {
                throw ImportError.malformed("il manque la couleur ANSI \(index).")
            }
            ansi.append(entry)
        }

        guard let background = color("Background Color"),
              let foreground = color("Foreground Color")
        else {
            throw ImportError.malformed("il manque la couleur de fond ou de texte.")
        }

        return Theme(
            name: fallbackName,
            source: .iTerm2,
            background: background,
            foreground: foreground,
            cursor: color("Cursor Color") ?? foreground,
            selectionBackground: color("Selection Color") ?? ansi[8],
            selectionForeground: color("Selected Text Color"),
            ansi: ansi
        )
    }

    // MARK: - base16

    /// Correspondance canonique base16 → ANSI, celle de `base16-shell`. Les
    /// couleurs vives reprennent volontairement les mêmes teintes : un schéma
    /// base16 n'en propose pas seize distinctes.
    private static let base16ToAnsi = [
        "base00", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base05",
        "base03", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base07",
    ]

    /// Accepte les deux générations du format : les clés `base00:` à plat, et
    /// la forme `palette:` de tinted-theming. Une ligne, une clé, une valeur —
    /// pas besoin d'un analyseur YAML complet pour ça.
    static func base16Theme(from text: String, fallbackName: String) throws -> Theme {
        var values: [String: String] = [:]
        var name: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: ":") else { continue }

            let key = String(line[line.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { continue }

            if key == "scheme" || key == "name" {
                name = value
            } else if key.hasPrefix("base"), key.count == 6 {
                values[key] = value
            }
        }

        let missing = (0..<16).map { String(format: "base%02X", $0).lowercased() }
            .filter { values[$0] == nil }
        guard missing.isEmpty else {
            throw ImportError.malformed(
                "il manque \(missing.count) couleur(s), à commencer par \(missing[0])."
            )
        }

        func color(_ key: String) -> ThemeColor {
            ThemeColor(hex: values[key.lowercased()] ?? "000000")
        }

        return Theme(
            name: name ?? fallbackName,
            source: .base16,
            background: color("base00"),
            foreground: color("base05"),
            cursor: color("base05"),
            selectionBackground: color("base02"),
            selectionForeground: nil,
            ansi: base16ToAnsi.map(color)
        )
    }
}
