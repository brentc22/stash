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

for size in sizes {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    NSColor.black.setFill()
    let radius = s * 0.22
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: radius, yRadius: radius).fill()

    let armLength = s * 0.28
    let lineWidth = s * 0.09
    let center = CGPoint(x: s * 0.46, y: s * 0.5)

    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: CGPoint(x: center.x - armLength * 0.5, y: center.y + armLength))
    path.line(to: CGPoint(x: center.x + armLength * 0.5, y: center.y))
    path.line(to: CGPoint(x: center.x - armLength * 0.5, y: center.y - armLength))
    NSColor.white.setStroke()
    path.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
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
