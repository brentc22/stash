#!/bin/zsh
# Generates Resources/Stash.icns without any external design tools.
#
# Draws a chevron directly with NSBezierPath rather than compositing an SF Symbol:
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

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

for size in sizes {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body, so Stash sits at the same size as system icons.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    shadow.set()
    rgb(0x10B8E8).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Mint into cyan into blue.
    NSGradient(colors: [rgb(0x3BF0A8), rgb(0x12C2E9), rgb(0x3D5AFE)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: bodyPath, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let glowCenter = NSPoint(x: body.midX - body.width * 0.2, y: body.maxY)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.3), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: body.width * 0.8, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // A frosted "menu bar" pill: the arrow on the left, colored status items
    // on the right shrinking and fading as they tuck away behind it.
    let pillW = body.width * 0.74, pillH = body.height * 0.3
    let pill = NSRect(x: body.midX - pillW / 2, y: body.midY - pillH / 2, width: pillW, height: pillH)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
    NSGraphicsContext.saveGraphicsState()
    let pillShadow = NSShadow()
    pillShadow.shadowColor = rgb(0x0B2A6B, 0.35)
    pillShadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    pillShadow.shadowBlurRadius = s * 0.03
    pillShadow.set()
    NSColor.white.withAlphaComponent(0.22).setFill()
    pillPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.5).setStroke()
    pillPath.lineWidth = max(1, s * 0.004)
    pillPath.stroke()

    // Chevron drawn by hand (see the note at the top about SF Symbols).
    let arm = pillH * 0.26
    let tip = CGPoint(x: pill.minX + pillH * 0.42, y: pill.midY)
    let chevron = NSBezierPath()
    chevron.lineWidth = pillH * 0.13
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: CGPoint(x: tip.x + arm, y: tip.y + arm))
    chevron.line(to: tip)
    chevron.line(to: CGPoint(x: tip.x + arm, y: tip.y - arm))
    NSColor.white.setStroke()
    chevron.stroke()

    let items: [(UInt32, CGFloat, CGFloat)] = [(0xFFD23F, 1.0, 1.0), (0xFF4F8B, 0.8, 1.0), (0xB15CFF, 0.6, 1.0)]
    var x = pill.minX + pillH * 1.05
    for (hex, scale, alpha) in items {
        let d = pillH * 0.4 * scale
        let r = NSRect(x: x, y: pill.midY - d / 2, width: d, height: d)
        rgb(hex, alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: d * 0.3, yRadius: d * 0.3).fill()
        x += d + pillH * 0.16
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let path2 = CommandLine.arguments[1] + "/icon_\(size)x\(size).png"
    try? png.write(to: URL(fileURLWithPath: path2))
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
