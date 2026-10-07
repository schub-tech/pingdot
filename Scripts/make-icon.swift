#!/usr/bin/env swift
// Renders Resources/AppIcon.icns — a green dot on a rounded dark tile.
// Run:  swift Scripts/make-icon.swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(side: Int) -> Data {
    let size = CGFloat(side)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let inset = size * 0.06
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let background = NSBezierPath(roundedRect: tile,
                                      xRadius: size * 0.22, yRadius: size * 0.22)
        NSGradient(starting: NSColor(calibratedWhite: 0.18, alpha: 1),
                   ending: NSColor(calibratedWhite: 0.07, alpha: 1))?
            .draw(in: background, angle: -90)

        let diameter = size * 0.46
        let dot = NSRect(x: (size - diameter) / 2, y: (size - diameter) / 2,
                         width: diameter, height: diameter)
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: dot).fill()

        NSColor.white.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -size * 0.09, dy: -size * 0.09))
        ring.lineWidth = max(1, size * 0.02)
        ring.stroke()
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not render \(side)px")
    }
    return png
}

for (side, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                     (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                     (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
                     (1024, "icon_512x512@2x")] {
    try render(side: side).write(to: iconset.appendingPathComponent("\(name).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
print(convert.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
