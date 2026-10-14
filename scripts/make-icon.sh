#!/bin/bash
# Export the app icon (apps/mac/Sources/LocalBot/AppIcon.swift) to assets/:
# AppIcon.png (1024) and AppIcon.icns for a future .app bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/assets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let flipped = NSAffineTransform()
    flipped.translateX(by: 0, yBy: CGFloat(size))
    flipped.scaleX(by: 1, yBy: -1)
    flipped.concat()
    AppIcon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(size).png"))
}
SWIFT

swiftc -O -o "$TMP/export" "$ROOT/apps/mac/Sources/LocalBot/AppIcon.swift" "$TMP/main.swift"
"$TMP/export" "$TMP"

mkdir -p "$OUT" "$TMP/AppIcon.iconset"
cp "$TMP/icon_1024.png" "$OUT/AppIcon.png"
for s in 16 32 128 256 512; do
  cp "$TMP/icon_$s.png" "$TMP/AppIcon.iconset/icon_${s}x${s}.png"
  cp "$TMP/icon_$((s * 2)).png" "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT/AppIcon.icns"
echo "Wrote $OUT/AppIcon.png and $OUT/AppIcon.icns"
