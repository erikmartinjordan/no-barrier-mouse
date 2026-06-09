#!/bin/bash
set -eu

OUTDIR="${1:-.build/icon}"
mkdir -p "$OUTDIR/mouse.iconset"

cat > /tmp/genicon.swift <<'SWIFT'
import AppKit
import Foundation

let w: CGFloat = 1024
let iconSize = NSSize(width: w, height: w)
let image = NSImage(size: iconSize)
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext

// ---- Background: rounded rect with gradient ----
let bgRect = CGRect(x: 0, y: 0, width: w, height: w)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 224, yRadius: 224)
bgPath.addClip()

let colors = [NSColor(red: 0.2, green: 0.35, blue: 0.7, alpha: 1).cgColor,
              NSColor(red: 0.35, green: 0.2, blue: 0.65, alpha: 1).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: w), end: CGPoint(x: w, y: 0), options: [])

// Subtle inner glow
let innerGlow = NSBezierPath(roundedRect: bgRect.insetBy(dx: 2, dy: 2), xRadius: 222, yRadius: 222)
NSColor(white: 1, alpha: 0.08).setStroke()
innerGlow.lineWidth = 4
innerGlow.stroke()

// ---- Mouse shadow ----
let shadowRect = NSRect(x: 280, y: 120, width: 460, height: 700)
let shadowPath = NSBezierPath(roundedRect: shadowRect.offsetBy(dx: 0, dy: -12), xRadius: 160, yRadius: 160)
NSColor(red: 0, green: 0, blue: 0.2, alpha: 0.25).setFill()
shadowPath.fill()

// ---- Mouse body ----
let bodyRect = NSRect(x: 280, y: 135, width: 460, height: 700)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 155, yRadius: 155)

// Body gradient
let bodyColors = [NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1).cgColor,
                  NSColor(red: 0.85, green: 0.85, blue: 0.9, alpha: 1).cgColor]
let bodyGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bodyColors as CFArray, locations: [0, 1])!
ctx.saveGState()
bodyPath.addClip()
ctx.drawLinearGradient(bodyGradient, start: CGPoint(x: 280, y: 500), end: CGPoint(x: 740, y: 500), options: [])
ctx.restoreGState()

// Body outline
NSColor(white: 0.55, alpha: 1).setStroke()
bodyPath.lineWidth = 6
bodyPath.stroke()

// ---- Button separation line ----
let sepLine = NSBezierPath()
sepLine.move(to: NSPoint(x: 512, y: 768))
sepLine.line(to: NSPoint(x: 512, y: 480))
NSColor(white: 0.65, alpha: 1).setStroke()
sepLine.lineWidth = 4
sepLine.stroke()

// ---- Left button highlight ----
let leftBtnRect = NSRect(x: 295, y: 500, width: 200, height: 250)
let leftBtnPath = NSBezierPath(roundedRect: leftBtnRect, xRadius: 90, yRadius: 90)
NSColor(white: 1, alpha: 0.3).setFill()
leftBtnPath.fill()

// ---- Right button highlight ----
let rightBtnRect = NSRect(x: 530, y: 500, width: 200, height: 250)
let rightBtnPath = NSBezierPath(roundedRect: rightBtnRect, xRadius: 90, yRadius: 90)
NSColor(white: 0.95, alpha: 0.2).setFill()
rightBtnPath.fill()

// ---- Scroll wheel ----
let wheelRect = NSRect(x: 482, y: 520, width: 60, height: 100)
let wheelPath = NSBezierPath(roundedRect: wheelRect, xRadius: 28, yRadius: 28)
NSColor(white: 0.7, alpha: 1).setFill()
wheelPath.fill()
NSColor(white: 0.5, alpha: 1).setStroke()
wheelPath.lineWidth = 3
wheelPath.stroke()

// Wheel lines
for yOff in stride(from: 30, through: 70, by: 20) {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 482, y: 520 + yOff))
    line.line(to: NSPoint(x: 542, y: 520 + yOff))
    NSColor(white: 0.5, alpha: 1).setStroke()
    line.lineWidth = 3
    line.stroke()
}

// ---- Connection arcs (sides) ----
func addArc(cx: CGFloat, cy: CGFloat, r: CGFloat, sa: CGFloat, ea: CGFloat) {
    let saRad = sa * .pi / 180
    let eaRad = ea * .pi / 180
    let from = NSPoint(x: cx + r * cos(saRad), y: cy + r * sin(saRad))
    let to = NSPoint(x: cx + r * cos(eaRad), y: cy + r * sin(eaRad))
    let arcPath = NSBezierPath()
    arcPath.appendArc(from: from, to: to, radius: r)
    NSColor(white: 1, alpha: 0.5).setStroke()
    arcPath.lineWidth = 4
    arcPath.lineCapStyle = .round
    arcPath.stroke()
}
addArc(cx: 200, cy: 480, r: 60, sa: -30, ea: 30)
addArc(cx: 200, cy: 480, r: 100, sa: -25, ea: 25)
addArc(cx: 200, cy: 480, r: 140, sa: -20, ea: 20)
addArc(cx: 824, cy: 480, r: 60, sa: 150, ea: 210)
addArc(cx: 824, cy: 480, r: 100, sa: 155, ea: 205)
addArc(cx: 824, cy: 480, r: 140, sa: 160, ea: 200)

// ---- Bottom indicator light ----
let lightRect = NSRect(x: 500, y: 160, width: 24, height: 24)
let lightPath = NSBezierPath(ovalIn: lightRect)
NSColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1).setFill()
lightPath.fill()
// Glow
NSColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 0.3).setFill()
let glowPath = NSBezierPath(ovalIn: lightRect.insetBy(dx: -8, dy: -8))
glowPath.fill()

// ---- Surface highlight (top of mouse) ----
let highlightPath = NSBezierPath(roundedRect: NSRect(x: 310, y: 750, width: 400, height: 60), xRadius: 30, yRadius: 30)
NSColor(white: 1, alpha: 0.25).setFill()
highlightPath.fill()

image.unlockFocus()

// Save as 1024x1024 PNG
guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("ERROR: failed to create CGImage")
    exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: cgImage)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    print("ERROR: failed to create PNG data")
    exit(1)
}
try data.write(to: URL(fileURLWithPath: "/tmp/mouse-icon-1024.png"))
print("OK")
SWIFT

swift /tmp/genicon.swift

echo "  Generating icon sizes..."
sips -z 16 16 /tmp/mouse-icon-1024.png --out "$OUTDIR/mouse.iconset/icon_16x16.png" &>/dev/null
cp "$OUTDIR/mouse.iconset/icon_16x16.png" "$OUTDIR/mouse.iconset/icon_16x16@2x.png"
sips -z 32 32 /tmp/mouse-icon-1024.png --out "$OUTDIR/mouse.iconset/icon_32x32.png" &>/dev/null
cp "$OUTDIR/mouse.iconset/icon_32x32.png" "$OUTDIR/mouse.iconset/icon_32x32@2x.png"
sips -z 128 128 /tmp/mouse-icon-1024.png --out "$OUTDIR/mouse.iconset/icon_128x128.png" &>/dev/null
cp "$OUTDIR/mouse.iconset/icon_128x128.png" "$OUTDIR/mouse.iconset/icon_128x128@2x.png"
sips -z 256 256 /tmp/mouse-icon-1024.png --out "$OUTDIR/mouse.iconset/icon_256x256.png" &>/dev/null
cp "$OUTDIR/mouse.iconset/icon_256x256.png" "$OUTDIR/mouse.iconset/icon_256x256@2x.png"
sips -z 512 512 /tmp/mouse-icon-1024.png --out "$OUTDIR/mouse.iconset/icon_512x512.png" &>/dev/null
cp "$OUTDIR/mouse.iconset/icon_512x512.png" "$OUTDIR/mouse.iconset/icon_512x512@2x.png"
cp /tmp/mouse-icon-1024.png "$OUTDIR/mouse.iconset/icon_512x512@2x.png"

echo "  Creating .icns..."
iconutil -c icns "$OUTDIR/mouse.iconset" -o "$OUTDIR/NoBarrierMouse.icns"
rm -rf "$OUTDIR/mouse.iconset"
rm -f /tmp/mouse-icon-1024.png /tmp/genicon.swift

echo "Done: $OUTDIR/NoBarrierMouse.icns"
