#!/usr/bin/env swift
//
// Generates a 1024x1024 placeholder app icon at icons/icon.png so build-app.sh
// has something to bake into Allofit.app. Designed to be "Icon Composer ready"
// - the output is a single flat 1024x1024 PNG, which is exactly what Apple's
// Icon Composer (macOS 26+) takes as a base layer when you want to refine
// the icon with Liquid Glass effects.
//
// Run from the project root:
//     swift make-placeholder-icon.swift
//     ./build-app.sh        # picks up icons/icon.png automatically
//
// Tweak the colors / shape constants below and re-run to iterate.

import AppKit
import CoreGraphics
import ImageIO
import Foundation

// ==================
// MARK: Tunables
// ==================

// Final image side length (px). 1024 is the largest slot the macOS iconset
// asks for so it works for every output size after sips downscales.
let kSizePixels: Int = 1024
// Apple's rounded-square corner radius is ~22.37% of side (classic) or
// ~25% (macOS 26 "Tahoe"). 22.37% is a safe middle ground.
let kCornerFactor: CGFloat = 0.2237
// Gradient stops (top-left to bottom-right): blue → teal
let kGradientStart = CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1)
let kGradientEnd   = CGColor(srgbRed: 0.13, green: 0.71, blue: 0.92, alpha: 1)
// Magnifying glass styling (in normalised 0..1 of the canvas)
let kGlassCenterX: CGFloat = 0.42
let kGlassCenterY: CGFloat = 0.58
let kGlassRadius: CGFloat  = 0.20
let kHandleLength: CGFloat = 0.22
let kStrokeWidth: CGFloat  = 0.06
// Output relative path
let kOutputPath = "icons/icon.png"

// ==================
// MARK: Draw
// ==================

let vSize = CGFloat(kSizePixels)
guard let vColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
	fputs("could not create sRGB color space\n", stderr); exit(1)
}
guard let ctx = CGContext(
	data: nil,
	width: kSizePixels,
	height: kSizePixels,
	bitsPerComponent: 8,
	bytesPerRow: 0,
	space: vColorSpace,
	bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
	fputs("could not create CG context\n", stderr); exit(2)
}

// Rounded-square mask matching Apple's app icon silhouette
let vRect = CGRect(x: 0, y: 0, width: vSize, height: vSize)
let vCornerRadius = vSize * kCornerFactor
let vMaskPath = CGPath(roundedRect: vRect,
					   cornerWidth: vCornerRadius,
					   cornerHeight: vCornerRadius,
					   transform: nil)

// Gradient background, clipped to the rounded square
ctx.saveGState()
ctx.addPath(vMaskPath)
ctx.clip()
let vGradient = CGGradient(
	colorsSpace: vColorSpace,
	colors: [kGradientStart, kGradientEnd] as CFArray,
	locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(vGradient,
	start: CGPoint(x: 0, y: vSize),
	end:   CGPoint(x: vSize, y: 0),
	options: [])
ctx.restoreGState()

// White magnifying glass on top
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(vSize * kStrokeWidth)
ctx.setLineCap(.round)

let vGlassCenter = CGPoint(x: vSize * kGlassCenterX, y: vSize * kGlassCenterY)
let vGlassR = vSize * kGlassRadius
ctx.strokeEllipse(in: CGRect(
	x: vGlassCenter.x - vGlassR,
	y: vGlassCenter.y - vGlassR,
	width: vGlassR * 2,
	height: vGlassR * 2
))

// Handle: from the lower-right edge of the glass, going down-right at -45°
let vAngle: CGFloat = -.pi / 4
let vHandleStart = CGPoint(
	x: vGlassCenter.x + vGlassR * cos(vAngle),
	y: vGlassCenter.y + vGlassR * sin(vAngle)
)
let vHandleLen = vSize * kHandleLength
let vHandleEnd = CGPoint(
	x: vHandleStart.x + vHandleLen * cos(vAngle),
	y: vHandleStart.y + vHandleLen * sin(vAngle)
)
ctx.move(to: vHandleStart)
ctx.addLine(to: vHandleEnd)
ctx.strokePath()

// ==================
// MARK: Write PNG
// ==================

guard let vCgImage = ctx.makeImage() else {
	fputs("could not create CGImage from context\n", stderr); exit(3)
}

try? FileManager.default.createDirectory(
	atPath: (kOutputPath as NSString).deletingLastPathComponent,
	withIntermediateDirectories: true
)
let vOutputURL = URL(fileURLWithPath: kOutputPath)
guard let vDest = CGImageDestinationCreateWithURL(
	vOutputURL as CFURL,
	"public.png" as CFString,
	1,
	nil
) else {
	fputs("could not create image destination\n", stderr); exit(4)
}
CGImageDestinationAddImage(vDest, vCgImage, nil)
guard CGImageDestinationFinalize(vDest) else {
	fputs("PNG finalize failed\n", stderr); exit(5)
}

print("Wrote \(kOutputPath) (\(kSizePixels)x\(kSizePixels))")
