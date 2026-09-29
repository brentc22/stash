#!/bin/zsh
# Generates Resources/Stash.icns without any external design tools.
#
# The mark: a neon chevron on a dark body, swallowing coloured status items that
# shrink and fade as they slide in — what Stash does to the menu bar.
#
# Draws the chevron directly with NSBezierPath rather than compositing an SF Symbol:
# an early version tried `NSImage(systemSymbolName: "chevron.left")` tinted via
# `NSColor.white.set()` before `.draw(in:)`, but a template symbol image drawn that
# way outside of an NSImageView/NSButton context ignores the fill color and renders
# with no visible mark at all — just a plain rounded square. Drawing the chevron's
# three line segments by hand sidesteps that and is easier to verify by eye anyway.
set -e
TMP=$(mktemp -d)
DIR="$TMP/Stash.iconset"
mkdir -p "$DIR"

cat > "$TMP/stash_icon.swift" <<'SWIFT'
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ size: Int) -> Data? {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // macOS icon grid: 824/1024 body.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    let u = body.width   // unit: everything below is a fraction of the body

    // Body: near-black indigo with a drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    shadow.set()
    rgb(0x0E0B1F).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(0x241A4D), rgb(0x0B0916)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: bodyPath, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()

    // The chevron's "mouth" sits left of centre; a warm glow spills out of it.
    let tip = CGPoint(x: body.minX + u * 0.30, y: body.midY)
    let glowC = CGPoint(x: tip.x + u * 0.08, y: tip.y)
    NSGradient(colors: [rgb(0xFF3D7F, 0.55), rgb(0xFF3D7F, 0.12), rgb(0xFF3D7F, 0)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: glowC, radius: 0, toCenter: glowC, radius: u * 0.55, options: [])

    // Status items being swallowed: coloured tiles that shrink, fade and trail
    // motion streaks as they slide into the chevron.
    let tiles: [(UInt32, CGFloat, CGFloat)] = [   // colour, x (fraction of u), size (fraction of u)
        (0x3BF0A8, 0.80, 0.135), (0xFFD23F, 0.60, 0.105), (0x4FA8FF, 0.445, 0.075),
    ]
    for (i, (hex, fx, fd)) in tiles.enumerated() {
        let d = u * fd
        let cx = body.minX + u * fx
        let alpha: CGFloat = [1, 0.85, 0.6][i]
        // streak behind it
        let streak = NSRect(x: cx, y: tip.y - d * 0.28, width: u * 0.17, height: d * 0.56)
        NSGradient(colors: [rgb(hex, 0.45 * alpha), rgb(hex, 0)])!
            .draw(in: NSBezierPath(roundedRect: streak, xRadius: d * 0.28, yRadius: d * 0.28), angle: 0)
        let r = NSRect(x: cx - d / 2, y: tip.y - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let g = NSShadow(); g.shadowColor = rgb(hex, 0.8 * alpha); g.shadowBlurRadius = u * 0.035; g.set()
        rgb(hex, alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: d * 0.3, yRadius: d * 0.3).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // The chevron: bold, rounded, hot pink into orange, with a neon glow.
    let arm = u * 0.20
    let chevron = NSBezierPath()
    chevron.lineWidth = u * 0.105
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: CGPoint(x: tip.x + arm, y: tip.y + arm * 1.05))
    chevron.line(to: tip)
    chevron.line(to: CGPoint(x: tip.x + arm, y: tip.y - arm * 1.05))
    let stroked = NSBezierPath()
    if let cg = chevron.cgPath.copy(strokingWithWidth: chevron.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10) as CGPath? {
        stroked.append(NSBezierPath(cgPath: cg))
    }
    NSGraphicsContext.saveGraphicsState()
    let neon = NSShadow(); neon.shadowColor = rgb(0xFF3D7F, 0.9); neon.shadowBlurRadius = u * 0.06; neon.set()
    rgb(0xFF3D7F).setFill(); stroked.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(0xFFA63D), rgb(0xFF3D7F), rgb(0xC03DFF)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: stroked, angle: -90)
    // specular highlight on the upper arm
    NSGraphicsContext.saveGraphicsState()
    stroked.addClip()
    NSGradient(colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: tip.x - u * 0.06, y: tip.y, width: arm + u * 0.12, height: arm * 1.2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Top sheen + hairline rim.
    NSGradient(colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: u, height: u / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    rgb(0xFFFFFF, 0.12).setStroke()
    bodyPath.lineWidth = max(1, s * 0.004)
    bodyPath.stroke()

    return rep.representation(using: .png, properties: [:])
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let png = render(size) else { continue }
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/icon_\(size)x\(size).png"))
}
SWIFT

swift "$TMP/stash_icon.swift" "$DIR"

# iconutil only accepts the ten standard iconset filenames. The loop above also
# writes icon_64x64.png and icon_1024x1024.png, which aren't among them — they
# exist only as source images for the @2x copies below and get removed after.
#
# zsh does not word-split an unquoted variable by default, so `set -- $pair`
# would leave $2 empty; `${pair% *}`/`${pair#* }` split "16 32" without relying
# on that.
for pair in "16 32" "32 64" "128 256" "256 512" "512 1024"; do
    small=${pair% *}
    big=${pair#* }
    cp "$DIR/icon_${big}x${big}.png" "$DIR/icon_${small}x${small}@2x.png"
done
rm -f "$DIR/icon_64x64.png" "$DIR/icon_1024x1024.png"

iconutil -c icns "$DIR" -o "$(dirname "$0")/Stash.icns"
echo "written: $(dirname "$0")/Stash.icns"
