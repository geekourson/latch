//
//  LocalizationTests.swift
//  LatchTests
//
//  Une traduction non testée dérive dès la chaîne suivante : on ajoute un
//  texte, on oublie l'anglais, et personne ne le voit avant qu'un anglophone
//  ouvre l'app.
//

import Foundation
import XCTest

@testable import Latch

@MainActor
final class LocalizationTests: XCTestCase {

    private func bundle(_ code: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: code, ofType: "lproj"),
            "paquet de langue \(code) absent du bundle"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    /// Le sentinelle : si la clé manque, on récupère cette valeur au lieu de la
    /// clé elle-même, et l'absence devient visible.
    private func translation(of key: String, in bundle: Bundle) -> String? {
        let missing = "⟨absente⟩"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }

    func testBothLanguagePacksShip() throws {
        XCTAssertNotNil(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        XCTAssertNotNil(Bundle.main.path(forResource: "en", ofType: "lproj"))
    }

    /// Un échantillon large, pris dans chaque écran : la barre latérale, le
    /// builder, les réglages, le panneau du §6, les hooks, l'authentification.
    func testEveryScreenIsTranslated() throws {
        let english = try bundle("en")
        let keys = [
            // Barre latérale
            "Nouvelle session", "Aucun serveur", "Sonder à nouveau", "Améliorer cet hôte…",
            "Retirer ce serveur…", "Renommer…", "Nouvelle fenêtre", "Ajouter au raccourci…",
            "Fermer la fenêtre", "Fenêtre suivante", "Fenêtre précédente",
            "Créer un raccourci ici", "Fermer la session…",
            // Terminal et barre d'état
            "aucune session", "Réessayer", "D'accord",
            // Builder
            "Connexion", "Transport", "À la création", "Pré-vol", "Fenêtres",
            "Ajouter une fenêtre", "Revenir au mode assisté", "Enregistrer", "Annuler",
            "À quoi ça sert ?", "clés par défaut du Mac",
            // Réglages
            "Langue", "Interface", "Police", "Thème", "Palette", "Ligatures",
            "Importer un thème…", "Braise (intégré)",
            // Panneau du §6
            "Diagnostic", "Distribution inconnue", "Pare-feu — optionnel",
            "Exécuter dans un panneau", "Copier", "Installer",
            "Ne plus proposer pour cet hôte", "Installés, mais hors du PATH", "Sur ce Mac",
            // Hooks et authentification
            "Hooks Latch", "Piloter Latch depuis Claude Code", "Authentification",
            "Configurer une clé…", "Mot de passe", "Oublier",
            // États
            "en attente", "connexion…", "latched on · dégradé", "échec",
            "shell seul", "ssh via rebond",
        ]

        let missing = keys.filter { translation(of: $0, in: english) == nil }
        XCTAssertTrue(missing.isEmpty, "sans traduction anglaise : \(missing)")
    }

    /// Les phrases longues sont celles qu'on oublie : elles sont écrites en
    /// concaténation et ne se voient pas dans un survol du code.
    func testTheLongParagraphsAreTranslated() throws {
        let english = try bundle("en")
        let paragraphs = [
            "Formats acceptés : .itermcolors (iTerm2) et les schémas base16 en .yaml.",
            "Ils font remonter l'activité de Claude Code : l'indicateur, le fichier en cours, et une notification quand une permission est attendue.",
            "Les hooks existants de ~/.claude/settings.json sont conservés, et une copie est mise de côté avant modification.",
            "Le jeton est tiré à chaque lancement de Latch : relancer l'app invalide l'accès précédent, et cette commande est à rejouer.",
        ]
        let missing = paragraphs.filter { translation(of: $0, in: english) == nil }
        XCTAssertTrue(missing.isEmpty, "paragraphes non traduits : \(missing)")
    }

    /// Une chaîne à trou doit garder son trou : une traduction qui perd son
    /// `%@` produit un texte amputé à l'exécution.
    func testFormatsKeepTheirPlaceholders() throws {
        let english = try bundle("en")
        for key in ["%@ absent", "%@ hors PATH", "1 fenêtre", "%d fenêtres", "il y a %d h"] {
            let value = try XCTUnwrap(translation(of: key, in: english), "clé absente : \(key)")
            for token in ["%@", "%d"] where key.contains(token) {
                XCTAssertTrue(value.contains(token), "« \(value) » a perdu son \(token)")
            }
        }
    }

    /// Traduire, ce n'est pas recopier : une valeur identique à sa clé est
    /// presque toujours un oubli — sauf pour les mots qui ne se traduisent pas.
    func testTranslationsActuallyDiffer() throws {
        let english = try bundle("en")
        let identicalOnPurpose: Set<String> = [
            "Latch", "Claude Code", "latched on", "mosh", "ssh", "tmux", "local",
            "Terminal", "Diagnostic", "Interface", "brew.sh", "~/.ssh/config",
            "Your sessions, still running.", "latch on to alex",
        ]
        let keys = ["Nouvelle session", "Enregistrer", "Annuler", "Fermer", "Supprimer",
                    "Fenêtres", "Pré-vol", "Langue", "Police", "Mot de passe"]

        for key in keys where !identicalOnPurpose.contains(key) {
            let value = try XCTUnwrap(translation(of: key, in: english))
            XCTAssertNotEqual(value, key, "« \(key) » n'a pas été traduit")
        }
    }

    // MARK: - Choix de la langue

    func testSystemLanguageResolvesToOneWeShip() {
        XCTAssertTrue(["fr", "en"].contains(Language.system.resolved))
        XCTAssertEqual(Language.french.resolved, "fr")
        XCTAssertEqual(Language.english.resolved, "en")
    }

    /// Le cœur du mécanisme : changer la langue change ce que `localized`
    /// rend, sans relancer l'app.
    func testSwitchingLanguageChangesTheStringsAtOnce() {
        Localization.apply(.french)
        XCTAssertEqual(localized("Nouvelle session"), "Nouvelle session")

        Localization.apply(.english)
        XCTAssertEqual(localized("Nouvelle session"), "New session")

        Localization.apply(.french)
        XCTAssertEqual(localized("Nouvelle session"), "Nouvelle session")
    }

    /// Une clé inconnue rend la clé : une chaîne oubliée s'affiche en français
    /// plutôt que de disparaître.
    func testAnUnknownKeyFallsBackToItself() {
        Localization.apply(.english)
        defer { Localization.apply(.french) }
        XCTAssertEqual(localized("Une phrase qui n'existe pas"), "Une phrase qui n'existe pas")
    }

    func testTheLanguageSurvivesARoundTripThroughTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-lang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("shortcuts.json")

        let store = SessionStore(fileURL: url, seedFromSSHConfig: false)
        XCTAssertEqual(store.preferences.language, .system)
        store.setLanguage(.english)
        store.saveNow()

        let reloaded = SessionStore(fileURL: url, seedFromSSHConfig: false)
        XCTAssertEqual(reloaded.preferences.language, .english)
        Localization.apply(.french)
    }
}
