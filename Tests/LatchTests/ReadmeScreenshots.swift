//
//  ReadmeScreenshots.swift
//  LatchTests
//
//  Les captures du README, refaites à la demande :
//
//      TEST_RUNNER_LATCH_SCREENSHOTS_DIR="$PWD/docs" xcodebuild test … \
//          -only-testing:LatchTests/ReadmeScreenshots
//
//  Sans la variable, le test est ignoré. La fenêtre est la vraie, dessinée
//  hors écran — aucune autorisation d'enregistrement d'écran n'est requise.
//  Les sessions aussi sont vraies, mais leurs noms d'hôte sont ceux d'une
//  démo, et chacune lance un process local qui affiche un contenu d'exemple :
//  une capture publique ne montre ni les serveurs ni le travail de personne.
//

import AppKit
import SwiftUI
import XCTest

@testable import Latch

@MainActor
final class ReadmeScreenshots: XCTestCase {

    private var output: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["LATCH_SCREENSHOTS_DIR"] else {
            throw XCTSkip("LATCH_SCREENSHOTS_DIR absent : captures non demandées")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-screenshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Localization.apply(.french)

        // Ce que lancent les sessions et l'inspecteur hérite de cet
        // environnement : un serveur tmux à part et un dossier personnel vide.
        // Sans ça, les vraies sessions tmux du Mac apparaîtraient dans la barre
        // latérale, et l'activité réelle de Claude Code dans les témoins.
        setenv("TMUX_TMPDIR", scratch.path, 1)
        setenv("HOME", scratch.path, 1)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Les captures

    /// La capture d'ouverture : quatre zones sur trois hôtes, celle des
    /// journaux verrouillée, Claude Code au travail dans la zone active.
    func testMainScreenshot() async throws {
        let (app, shortcuts) = try await stage()
        app.apply(.grid2x2)
        let zones = app.layout.zones.map(\.id)
        for (index, name) in ["api", "logs", "train", "latch"].enumerated() {
            await app.open(shortcuts[name]!, into: zones[index])
        }
        app.toggleLock(zones[1])
        app.focus(zones[0])

        try await capture(app, size: CGSize(width: 1560, height: 920), to: "screenshot.png")
        app.closeAll()
    }

    /// Le glisser-déposer : une session lâchée sur le bord droit d'une zone.
    func testDropScreenshot() async throws {
        let (app, shortcuts) = try await stage()
        app.apply(.sideBySide)
        let zones = app.layout.zones.map(\.id)
        await app.open(shortcuts["api"]!, into: zones[0])
        await app.open(shortcuts["latch"]!, into: zones[1])
        app.focus(zones[0])

        try await capture(app, size: CGSize(width: 1560, height: 820), to: "zones-drop.png") {
            let target = app.zoneFrames[zones[1]]!
            app.draggedItem = .shortcut(shortcuts["logs"]!.id)
            app.updateDropHint(at: CGPoint(x: target.maxX - 30, y: target.midY))
        }
        app.closeAll()
    }

    /// Un écran large : huit zones, quatre colonnes sur deux rangées.
    func testWideScreenshot() async throws {
        let (app, shortcuts) = try await stage()
        app.apply(.grid4x2)
        let zones = app.layout.zones.map(\.id)
        let order = ["api", "logs", "train", "latch", "edge", "db", "notes", "staging"]
        for (index, name) in order.enumerated() {
            await app.open(shortcuts[name]!, into: zones[index])
        }
        app.toggleLock(zones[1])
        app.focus(zones[0])

        try await capture(app, size: CGSize(width: 2400, height: 980), to: "zones-wide.png")
        app.closeAll()
    }

    // MARK: - Mise en scène

    private struct Demo {
        let name: String
        let host: String
        let content: String
    }

    /// Trois hôtes de démo, et le Mac. Les sondes sont posées d'avance : rien
    /// ne cherche à joindre ces noms.
    private func stage() async throws -> (AppState, [String: Shortcut]) {
        let store = SessionStore(
            fileURL: scratch.appendingPathComponent("shortcuts-\(UUID().uuidString).json"),
            seedFromSSHConfig: false
        )
        let complete = ProbeResult(hasTmux: true, tmuxVersion: "3.4", hasMoshServer: true,
                                   hasClaude: true, osID: "debian")
        store.servers = ["prod-eu", "gpu-box", "staging-eu"].map { alias in
            Server(name: alias, sshAlias: alias, probe: complete, probedAt: Date())
        }

        var shortcuts: [String: Shortcut] = [:]
        for demo in Self.demos {
            let file = scratch.appendingPathComponent("\(demo.name).ans")
            try demo.content.write(to: file, atomically: true, encoding: .utf8)
            // Le contenu s'affiche, puis le process attend : la session reste
            // « latched on » le temps de la capture.
            let shortcut = Shortcut(
                name: demo.name,
                connection: Connection(transport: demo.host.isEmpty ? .local : .ssh,
                                       host: demo.host, tmuxSession: demo.name),
                customCommand: "stty -echo; cat \(ShellQuoting.quoted(file.path)); exec sleep 86400"
            )
            store.add(shortcut)
            shortcuts[demo.name] = shortcut
        }
        return (AppState(store: store), shortcuts)
    }

    /// Photographie la vraie fenêtre, hors écran, à la résolution Retina.
    ///
    /// Par le serveur de fenêtres : ni `cacheDisplay` ni le rendu des calques
    /// ne voient ce que SwiftUI dessine sur le GPU — la barre latérale, la
    /// bande du haut, les fonds. Une app peut photographier ses propres
    /// fenêtres sans autorisation d'enregistrement d'écran.
    private func capture(
        _ app: AppState, size: CGSize, to name: String,
        beforeCapture: () -> Void = {}
    ) async throws {
        let window = UnconstrainedWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        // Créée par le code, une fenêtre se libère d'elle-même à la fermeture,
        // et l'est une seconde fois ensuite.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        )
        // Montrée, mais hors de l'écran : le serveur de fenêtres la compose,
        // et personne ne la voit passer.
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: window.frame.size),
                        display: true)
        window.layoutIfNeeded()

        // Le temps que les terminaux démarrent, affichent, et que la notice
        // d'un verrou s'efface.
        try await Task.sleep(for: .seconds(3))
        beforeCapture()
        try await Task.sleep(for: .milliseconds(400))

        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(200))

        let image = try XCTUnwrap(Self.windowImage(window.windowNumber), "capture refusée")
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name))
        window.close()
    }

    /// `CGWindowListCreateImage` est retirée du SDK au profit de
    /// ScreenCaptureKit, qui exige l'autorisation d'enregistrer l'écran. La
    /// fonction existe toujours : on la cherche à l'exécution.
    private static func windowImage(_ windowNumber: Int) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingAndBestResolution: UInt32 = (1 << 0) | (1 << 3)
        return capture(.null, includingWindow, UInt32(windowNumber), ignoreFramingAndBestResolution)?
            .takeRetainedValue()
    }

    // MARK: - Contenus d'exemple

    private static let esc = "\u{1B}["
    private static func rgb(_ hex: Int) -> String {
        "\(esc)38;2;\((hex >> 16) & 0xFF);\((hex >> 8) & 0xFF);\(hex & 0xFF)m"
    }
    private static let reset = "\u{1B}[0m"
    private static let green = rgb(0x8FB09A), amber = rgb(0xC89B6A), dim = rgb(0x7C6F63)
    private static let violet = rgb(0xB3A0D6), blue = rgb(0x7E9CC0), red = rgb(0xC96A5E)
    private static let cyan = rgb(0x86B4B0), text = rgb(0xEDE4D8)

    private static func prompt(_ host: String, _ dir: String = "~") -> String {
        "\(green)deploy@\(host)\(reset):\(blue)\(dir)\(reset)$ "
    }

    private static func lines(_ items: [String]) -> String {
        items.joined(separator: "\r\n") + "\r\n"
    }

    private static let demos: [Demo] = [
        Demo(name: "api", host: "prod-eu", content: lines([
            "\(violet)✳ Claude Code\(reset)  \(dim)~/srv/api\(reset)",
            "",
            "\(dim)›\(reset) le limiteur de débit laisse passer des rafales, corrige-le",
            "",
            "\(violet)●\(reset) Je lis \(cyan)src/ratelimit/bucket.ts\(reset) et ses tests.",
            "\(violet)●\(reset) Le seau se remplit avant d'être vidé : une rafale passe à",
            "  chaque changement de seconde.",
            "",
            "\(violet)●\(reset) Update(\(cyan)src/ratelimit/bucket.ts\(reset))",
            "  \(green)+   const refill = Math.min(capacity, tokens + elapsed * rate)\(reset)",
            "  \(red)-   tokens = capacity\(reset)",
            "  \(green)+   tokens = refill - 1\(reset)",
            "",
            "\(violet)●\(reset) Bash(npm test -- ratelimit)",
            "  \(green)✓ 23 tests passés\(reset) \(dim)(2,1 s)\(reset)",
            "",
            "\(amber)✶ Réflexion…\(reset) \(dim)(esc pour interrompre)\(reset)",
        ])),
        Demo(name: "logs", host: "prod-eu", content: lines([
            prompt("prod-eu") + "journalctl -u api -f -o short-iso",
            "\(dim)2026-11-18T14:02:11\(reset) api[812]: GET /v2/orders 200 18ms",
            "\(dim)2026-11-18T14:02:11\(reset) api[812]: POST /v2/orders 201 42ms",
            "\(dim)2026-11-18T14:02:12\(reset) api[812]: GET /health 200 1ms",
            "\(dim)2026-11-18T14:02:13\(reset) api[812]: \(amber)WARN\(reset) rate limit burst from 10.4.2.17",
            "\(dim)2026-11-18T14:02:13\(reset) api[812]: GET /v2/orders 429 0ms",
            "\(dim)2026-11-18T14:02:14\(reset) api[812]: GET /v2/catalog 200 27ms",
            "\(dim)2026-11-18T14:02:15\(reset) api[812]: GET /v2/orders/9f3c 200 9ms",
            "\(dim)2026-11-18T14:02:16\(reset) api[812]: POST /v2/payments 201 88ms",
            "\(dim)2026-11-18T14:02:17\(reset) api[812]: GET /health 200 1ms",
        ])),
        Demo(name: "train", host: "gpu-box", content: lines([
            prompt("gpu-box", "~/runs/vit-b16") + "tail -f train.log",
            "epoch 14/40  step 3120  \(dim)loss\(reset) 0.4127  \(dim)lr\(reset) 2.1e-4  \(dim)it/s\(reset) 7.9",
            "epoch 14/40  step 3140  \(dim)loss\(reset) 0.4093  \(dim)lr\(reset) 2.1e-4  \(dim)it/s\(reset) 8.0",
            "epoch 14/40  step 3160  \(dim)loss\(reset) 0.4101  \(dim)lr\(reset) 2.1e-4  \(dim)it/s\(reset) 7.9",
            "\(green)eval\(reset)  top-1 \(text)81.4 %\(reset)  top-5 \(text)95.7 %\(reset)  \(dim)(best 81.4)\(reset)",
            "checkpoint saved → ckpt/epoch-14.pt",
            "epoch 15/40  step 3180  \(dim)loss\(reset) 0.4052  \(dim)lr\(reset) 2.0e-4  \(dim)it/s\(reset) 8.1",
            "epoch 15/40  step 3200  \(dim)loss\(reset) 0.3988  \(dim)lr\(reset) 2.0e-4  \(dim)it/s\(reset) 8.0",
        ])),
        Demo(name: "latch", host: "", content: lines([
            "\(green)billy@mac\(reset) \(blue)~/dev/latch\(reset) % git log --oneline -12",
            "\(amber)b96af9a\(reset) Afficher plusieurs terminaux à l'écran dans des zones",
            "\(amber)82743aa\(reset) Retirer la barre d'onglets au profit de la barre latérale",
            "\(amber)85064b5\(reset) Rendre le glisser à tmux et copier l'historique de la fenêtre",
            "\(amber)aef2819\(reset) Mettre Latch à jour automatiquement avec Sparkle",
            "\(amber)e9e883f\(reset) Garder la sélection pendant que la session écrit",
            "\(amber)3926b27\(reset) Sonder à nouveau un hôte dégradé à chaque connexion",
            "\(amber)d7ce586\(reset) Refuser les hôtes MCP inconnus ou pris pour des options ssh",
            "\(amber)d4e31b3\(reset) Ne republier l'état tmux que lorsqu'il change",
            "\(green)billy@mac\(reset) \(blue)~/dev/latch\(reset) % ",
        ])),
        Demo(name: "edge", host: "prod-eu", content: lines([
            prompt("prod-eu") + "sudo nginx -t && sudo systemctl reload nginx",
            "nginx: the configuration file /etc/nginx/nginx.conf syntax is ok",
            "nginx: configuration file /etc/nginx/nginx.conf test is \(green)successful\(reset)",
            prompt("prod-eu"),
        ])),
        Demo(name: "db", host: "prod-eu", content: lines([
            prompt("prod-eu") + "psql -c 'select state, count(*) from pg_stat_activity group by 1'",
            "  state  | count",
            "---------+-------",
            " active  |     4",
            " idle    |    37",
            "(2 rows)",
            "",
            prompt("prod-eu"),
        ])),
        Demo(name: "notes", host: "", content: lines([
            "\(green)billy@mac\(reset) \(blue)~/notes\(reset) % cat todo.md",
            "- [x] limiteur de débit",
            "- [ ] migrer les paiements vers v3",
            "- [ ] relancer l'entraînement avec mixup",
            "\(green)billy@mac\(reset) \(blue)~/notes\(reset) % ",
        ])),
        Demo(name: "staging", host: "staging-eu", content: lines([
            prompt("staging-eu") + "./deploy.sh api v2.31.0",
            "\(dim)→\(reset) pull image api:v2.31.0",
            "\(dim)→\(reset) migrate: 2 migrations applied",
            "\(dim)→\(reset) health check \(green)ok\(reset)",
            "\(green)✓ déployé en 41 s\(reset)",
            prompt("staging-eu"),
        ])),
    ]
}

/// Une fenêtre que macOS ne ramène pas aux dimensions de l'écran : la capture
/// « écran large » est plus large que celui d'un portable.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
