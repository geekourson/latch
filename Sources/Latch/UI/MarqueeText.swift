//
//  MarqueeText.swift
//  Latch
//
//  Un nom trop long pour sa ligne : coupé par « … » au repos, il défile au
//  survol jusqu'à sa fin, s'y arrête, puis revient — de quoi le lire en
//  entier sans élargir la barre latérale.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    /// Le survol de la ligne, que la ligne connaît déjà.
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fullWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Points par seconde : assez lent pour lire en suivant.
    private static let speed: CGFloat = 40
    private static let pause: Duration = .milliseconds(900)

    private var overflow: CGFloat { max(0, fullWidth - visibleWidth) }
    private var isScrolling: Bool { isActive && overflow > 1 && !reduceMotion }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isScrolling ? 0 : 1)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { visibleWidth = $0 }
            // La largeur entière, mesurée sans place à respecter.
            .background(alignment: .leading) {
                Text(text)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { fullWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if isScrolling {
                    Text(text)
                        .fixedSize()
                        .offset(x: offset)
                }
            }
            .clipped()
            .task(id: isScrolling) {
                offset = 0
                guard isScrolling else { return }
                await scroll()
            }
    }

    /// Aller jusqu'à la fin, s'y arrêter, revenir, recommencer — tant que la
    /// souris reste sur la ligne.
    private func scroll() async {
        let duration = Double(overflow / Self.speed)
        while !Task.isCancelled {
            guard (try? await Task.sleep(for: Self.pause)) != nil else { return }
            withAnimation(.linear(duration: duration)) { offset = -overflow }
            guard (try? await Task.sleep(for: .seconds(duration) + Self.pause)) != nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { offset = 0 }
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
        }
    }
}
