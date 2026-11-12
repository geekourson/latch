//
//  Updater.swift
//  Latch
//
//  Les mises à jour automatiques, confiées à Sparkle. Le flux est publié avec
//  chaque release (`appcast.xml`) et chaque archive y est signée en EdDSA : la
//  clé publique est dans l'Info.plist, une archive qui ne la vérifie pas est
//  refusée, quand bien même GitHub la servirait.
//
//  Une mise à jour trouvée se télécharge en silence et s'installe à la
//  fermeture de Latch, jamais en coupant un onglet — un shell local sans tmux
//  n'y survivrait pas.
//

import Combine
import Sparkle

@MainActor
final class Updater: ObservableObject {

    /// Faux pendant qu'une recherche est déjà en cours.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?

    init() {
        // Une compilation de développement porte le numéro de la dernière
        // release, ou un plus ancien : elle se ferait remplacer par la version
        // publiée au premier lancement.
        #if DEBUG
        controller = nil
        #else
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        #endif
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle range ce choix dans ses propres préférences.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }
}
