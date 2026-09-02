//
//  ThemeImporterTests.swift
//  LatchTests
//
//  L'import de thèmes du §9.3, sur les deux formats que Latch accepte.
//

import Foundation
import XCTest

@testable import Latch

final class ThemeColorTests: XCTestCase {

    func testAcceptsTheUsualHexShapes() {
        XCTAssertEqual(ThemeColor(hex: "#2b303b").hex, "2B303B")
        XCTAssertEqual(ThemeColor(hex: "2b303b").hex, "2B303B")
        XCTAssertEqual(ThemeColor(hex: "  #ABC  ").hex, "AABBCC")
    }

    func testRejectsNonsenseWithoutCrashing() {
        XCTAssertEqual(ThemeColor(hex: "pas une couleur").hex, "000000")
        XCTAssertEqual(ThemeColor(hex: "").hex, "000000")
    }

    /// Les composantes d'un `.itermcolors` sont flottantes, et un fichier venu
    /// d'un espace large peut sortir de [0,1] : on ramène dans sRGB plutôt que
    /// de refuser le fichier.
    func testClampsFloatingComponents() {
        XCTAssertEqual(ThemeColor(red: 1, green: 0, blue: 0).hex, "FF0000")
        XCTAssertEqual(ThemeColor(red: 1.4, green: -0.2, blue: 0.5).hex, "FF0080")
    }

    func testRoundTripsThroughAnInteger() {
        XCTAssertEqual(ThemeColor(0xC89B6A).hex, "C89B6A")
        XCTAssertEqual(ThemeColor(hex: "C89B6A").value, 0xC89B6A)
    }
}

final class ThemeImporterTests: XCTestCase {

    // MARK: - base16

    /// L'ancien format, à plat.
    private let ocean = """
        scheme: "Ocean"
        author: "Chris Kempson"
        base00: "2b303b"
        base01: "343d46"
        base02: "4f5b66"
        base03: "65737e"
        base04: "a7adba"
        base05: "c0c5ce"
        base06: "dfe1e8"
        base07: "eff1f5"
        base08: "bf616a"
        base09: "d08770"
        base0A: "ebcb8b"
        base0B: "a3be8c"
        base0C: "96b5b4"
        base0D: "8fa1b3"
        base0E: "b48ead"
        base0F: "ab7967"
        """

    /// La forme tinted-theming, avec `palette:` et des dièses.
    private let tomorrow = """
        system: "base16"
        name: "Tomorrow Night"
        author: "Chris Kempson"
        variant: "dark"
        palette:
          base00: "#1d1f21"
          base01: "#282a2e"
          base02: "#373b41"
          base03: "#969896"
          base04: "#b4b7b4"
          base05: "#c5c8c6"
          base06: "#e0e0e0"
          base07: "#ffffff"
          base08: "#cc6666"
          base09: "#de935f"
          base0A: "#f0c674"
          base0B: "#b5bd68"
          base0C: "#8abeb7"
          base0D: "#81a2be"
          base0E: "#b294bb"
          base0F: "#a3685a"
        """

    func testImportsAFlatBase16Scheme() throws {
        let theme = try ThemeImporter.base16Theme(from: ocean, fallbackName: "fichier")
        XCTAssertEqual(theme.name, "Ocean")
        XCTAssertEqual(theme.source, .base16)
        XCTAssertEqual(theme.background.hex, "2B303B")  // base00
        XCTAssertEqual(theme.foreground.hex, "C0C5CE")  // base05
        XCTAssertEqual(theme.selectionBackground.hex, "4F5B66")  // base02
        XCTAssertTrue(theme.isValid)
    }

    func testImportsTheTintedThemingShape() throws {
        let theme = try ThemeImporter.base16Theme(from: tomorrow, fallbackName: "fichier")
        XCTAssertEqual(theme.name, "Tomorrow Night")
        XCTAssertEqual(theme.background.hex, "1D1F21")
        XCTAssertEqual(theme.ansi.count, 16)
    }

    /// La correspondance canonique de `base16-shell` : rouge = base08,
    /// vert = base0B, jaune = base0A, bleu = base0D, magenta = base0E,
    /// cyan = base0C.
    func testUsesTheCanonicalBase16ToAnsiMapping() throws {
        let theme = try ThemeImporter.base16Theme(from: ocean, fallbackName: "fichier")
        XCTAssertEqual(theme.ansi[0].hex, "2B303B")  // base00
        XCTAssertEqual(theme.ansi[1].hex, "BF616A")  // base08, rouge
        XCTAssertEqual(theme.ansi[2].hex, "A3BE8C")  // base0B, vert
        XCTAssertEqual(theme.ansi[3].hex, "EBCB8B")  // base0A, jaune
        XCTAssertEqual(theme.ansi[4].hex, "8FA1B3")  // base0D, bleu
        XCTAssertEqual(theme.ansi[5].hex, "B48EAD")  // base0E, magenta
        XCTAssertEqual(theme.ansi[6].hex, "96B5B4")  // base0C, cyan
        XCTAssertEqual(theme.ansi[7].hex, "C0C5CE")  // base05
        XCTAssertEqual(theme.ansi[8].hex, "65737E")  // base03, noir vif
        XCTAssertEqual(theme.ansi[15].hex, "EFF1F5") // base07, blanc vif
    }

    func testIncompleteSchemeIsRefusedWithAUsefulMessage() {
        let truncated = ocean.split(separator: "\n").prefix(8).joined(separator: "\n")
        XCTAssertThrowsError(try ThemeImporter.base16Theme(from: truncated, fallbackName: "x")) {
            XCTAssertTrue($0.localizedDescription.contains("base"), $0.localizedDescription)
        }
    }

    func testFallsBackToTheFileNameWhenTheSchemeIsUnnamed() throws {
        let anonymous = ocean.split(separator: "\n").dropFirst(2).joined(separator: "\n")
        let theme = try ThemeImporter.base16Theme(from: anonymous, fallbackName: "ocean-dark")
        XCTAssertEqual(theme.name, "ocean-dark")
    }

    // MARK: - iTerm2

    private func itermPlist(includeCursor: Bool = true) throws -> Data {
        func color(_ red: Double, _ green: Double, _ blue: Double) -> [String: Any] {
            [
                "Color Space": "sRGB",
                "Red Component": red,
                "Green Component": green,
                "Blue Component": blue,
                "Alpha Component": 1.0,
            ]
        }

        var root: [String: Any] = [:]
        for index in 0..<16 {
            root["Ansi \(index) Color"] = color(Double(index) / 15.0, 0, 0)
        }
        root["Background Color"] = color(0, 0, 0)
        root["Foreground Color"] = color(1, 1, 1)
        root["Selection Color"] = color(0.2, 0.2, 0.2)
        if includeCursor { root["Cursor Color"] = color(1, 0.5, 0) }

        return try PropertyListSerialization.data(
            fromPropertyList: root, format: .xml, options: 0
        )
    }

    func testImportsAnITermColorsFile() throws {
        let theme = try ThemeImporter.iTerm2Theme(from: itermPlist(), fallbackName: "Solarized")
        XCTAssertEqual(theme.name, "Solarized")
        XCTAssertEqual(theme.source, .iTerm2)
        XCTAssertEqual(theme.ansi.count, 16)
        XCTAssertEqual(theme.background.hex, "000000")
        XCTAssertEqual(theme.foreground.hex, "FFFFFF")
        XCTAssertEqual(theme.cursor.hex, "FF8000")
        XCTAssertEqual(theme.ansi[0].hex, "000000")
        XCTAssertEqual(theme.ansi[15].hex, "FF0000")
    }

    /// Un fichier sans couleur de curseur reste importable : on retombe sur la
    /// couleur du texte plutôt que de refuser le thème.
    func testMissingCursorFallsBackToTheForeground() throws {
        let theme = try ThemeImporter.iTerm2Theme(
            from: itermPlist(includeCursor: false), fallbackName: "x"
        )
        XCTAssertEqual(theme.cursor.hex, theme.foreground.hex)
    }

    func testMissingAnsiColourIsRefused() throws {
        var root = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: itermPlist(), options: [], format: nil
            ) as? [String: Any]
        )
        root.removeValue(forKey: "Ansi 7 Color")
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .xml, options: 0
        )
        XCTAssertThrowsError(try ThemeImporter.iTerm2Theme(from: data, fallbackName: "x")) {
            XCTAssertTrue($0.localizedDescription.contains("7"), $0.localizedDescription)
        }
    }

    func testGarbageIsRefused() {
        XCTAssertThrowsError(
            try ThemeImporter.iTerm2Theme(from: Data("pas un plist".utf8), fallbackName: "x")
        )
    }

    // MARK: - Choix du format

    func testUnknownExtensionIsRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).toml")
        try "rien".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThemeImporter.theme(contentsOf: url)) {
            XCTAssertTrue($0.localizedDescription.contains("toml"), $0.localizedDescription)
        }
    }

    func testDispatchesOnTheExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let yaml = directory.appendingPathComponent("ocean.yaml")
        try ocean.write(to: yaml, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ThemeImporter.theme(contentsOf: yaml).source, .base16)

        let plist = directory.appendingPathComponent("Solarized.itermcolors")
        try itermPlist().write(to: plist)
        XCTAssertEqual(try ThemeImporter.theme(contentsOf: plist).source, .iTerm2)
    }
}

@MainActor
final class ThemeStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-theme-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SessionStore {
        SessionStore(
            fileURL: directory.appendingPathComponent("shortcuts.json"),
            seedFromSSHConfig: false
        )
    }

    private func writeScheme(named name: String) throws -> URL {
        let url = directory.appendingPathComponent("\(name).yaml")
        var lines = ["scheme: \"\(name)\""]
        for index in 0..<16 {
            lines.append(String(format: "base%02X: \"1a2b3c\"", index))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testImportingAThemeSelectsIt() throws {
        let store = makeStore()
        XCTAssertEqual(store.activeTheme.name, "Braise")

        let theme = try store.importTheme(at: writeScheme(named: "Ocean"))
        XCTAssertEqual(store.preferences.themeID, theme.id)
        XCTAssertEqual(store.activeTheme.name, "Ocean")
        XCTAssertEqual(store.terminalStyle.theme.background.hex, "1A2B3C")
    }

    /// Réimporter le même fichier remplace le thème au lieu d'empiler un
    /// doublon dans le sélecteur.
    func testReimportingReplacesRatherThanDuplicates() throws {
        let store = makeStore()
        let url = try writeScheme(named: "Ocean")
        let first = try store.importTheme(at: url)
        let second = try store.importTheme(at: url)

        XCTAssertEqual(store.themes.count, 1)
        XCTAssertEqual(first.id, second.id)
    }

    func testThemesSurviveARoundTrip() throws {
        let store = makeStore()
        _ = try store.importTheme(at: writeScheme(named: "Ocean"))
        store.preferences.fontName = "Menlo"
        store.preferences.fontSize = 15
        store.saveNow()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.themes.map(\.name), ["Ocean"])
        XCTAssertEqual(reloaded.activeTheme.name, "Ocean")
        XCTAssertEqual(reloaded.preferences.fontName, "Menlo")
        XCTAssertEqual(reloaded.terminalStyle.fontSize, 15)
    }

    /// Retirer le thème actif ramène à la palette intégrée, qui elle ne se
    /// supprime pas.
    func testRemovingTheActiveThemeFallsBackToEmber() throws {
        let store = makeStore()
        let theme = try store.importTheme(at: writeScheme(named: "Ocean"))
        store.removeTheme(id: theme.id)

        XCTAssertTrue(store.themes.isEmpty)
        XCTAssertNil(store.preferences.themeID)
        XCTAssertEqual(store.activeTheme.name, "Braise")
    }

    /// La palette « braise » du §9.3, telle qu'elle est écrite dans la SPEC.
    func testEmberMatchesTheSpec() {
        XCTAssertEqual(Theme.ember.background.hex, "17130F")
        XCTAssertEqual(Theme.ember.foreground.hex, "EDE4D8")
        XCTAssertEqual(Theme.ember.cursor.hex, "C89B6A")
        XCTAssertEqual(Theme.ember.ansi.count, 16)
    }
}
