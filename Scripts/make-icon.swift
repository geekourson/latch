// Générateur de l'icône de Latch.
//
// Le dessin est une pièce de menuiserie : un moraillon — l'arceau — posé sur sa
// gâche. C'est littéralement un loquet, et la silhouette tient à 16 pixels
// parce qu'elle se réduit à deux formes : un arc et une barre.
//
// La palette est celle de l'app (LatchTheme) : braise en fond, ambre pour
// l'arceau, crème pour la barre.

import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Dessine l'icône dans un carré de `size` points.
func draw(size: CGFloat, in context: CGContext) {
    let scale = size / 1024

    // macOS inscrit le contenu dans un carré arrondi qui n'occupe pas toute la
    // toile : 824 sur 1024, le reste étant la marge que le système attend.
    let inset = (1024 - 824) / 2 * scale
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = 185 * scale

    let shape = CGPath(
        roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    // Le fond : un dégradé vertical de la braise, plus clair en haut comme une
    // surface qui prend la lumière.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x2E2219), color(0x17130F)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: body.maxY),
        end: CGPoint(x: 0, y: body.minY),
        options: []
    )
    context.restoreGState()

    // Un liseré intérieur : il détache l'icône d'un fond sombre sans peser.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(color(0x3A302A))
    context.setLineWidth(6 * scale)
    context.strokePath()
    context.restoreGState()

    // Le repère du dessin : le centre de la toile.
    context.saveGState()
    context.translateBy(x: size / 2, y: size / 2)
    context.scaleBy(x: scale, y: scale)

    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Un verrou vu de face : le pêne entre par la gauche dans sa gâche. Deux
    // formes, l'une horizontale, l'autre en « ⊐ » — la silhouette tient en
    // tout petit parce qu'elle n'a aucun détail à perdre.

    // La gâche : un cadre ouvert du côté par lequel le pêne arrive.
    let keeper = CGMutablePath()
    keeper.move(to: CGPoint(x: 10, y: 215))
    keeper.addLine(to: CGPoint(x: 205, y: 215))
    keeper.addArc(
        tangent1End: CGPoint(x: 290, y: 215), tangent2End: CGPoint(x: 290, y: 130), radius: 85
    )
    keeper.addLine(to: CGPoint(x: 290, y: -130))
    keeper.addArc(
        tangent1End: CGPoint(x: 290, y: -215), tangent2End: CGPoint(x: 205, y: -215), radius: 85
    )
    keeper.addLine(to: CGPoint(x: 10, y: -215))

    context.saveGState()
    context.setLineWidth(96)
    context.addPath(keeper)
    context.setStrokeColor(color(0xEDE4D8))
    context.strokePath()
    context.restoreGState()

    // Le pêne : engagé jusqu'au fond, pas simplement posé devant.
    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: -295, y: 0))
    bolt.addLine(to: CGPoint(x: 150, y: 0))

    context.saveGState()
    context.setLineWidth(118)
    context.addPath(bolt)
    context.setStrokeColor(color(0xC89B6A))
    context.strokePath()
    context.restoreGState()

    context.restoreGState()
}

func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    draw(size: CGFloat(size), in: context)
    return context.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let representation = NSBitmapImageRep(cgImage: image)
    let data = representation.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// Les tailles qu'attend un iconset macOS, chacune en simple et double densité.
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    write(render(size: size), to: "\(outputDirectory)/icon_\(size)x\(size).png")
    write(render(size: size * 2), to: "\(outputDirectory)/icon_\(size)x\(size)@2x.png")
}
print("rendu : \(sizes.count * 2) images dans \(outputDirectory)")
