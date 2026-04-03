import Cocoa
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration

// Input: Square PNG master (1024x1024), pass as first argument
let inputMasterPath: String = {
    guard CommandLine.arguments.count > 1 else {
        print("Usage: swift Tools/MakeAppIcon.swift <input-master.png>")
        exit(1)
    }
    return CommandLine.arguments[1]
}()

// Intermediate: Squircle-masked + shadow version
let maskedMasterPath = "Veil/AppIcon-Master-Masked.png"

// Output: The directory where the final assets will be placed
let outputDir = "Veil/Assets.xcassets/AppIcon.appiconset"

// Visual Tuning
let canvasSize = CGSize(width: 1024, height: 1024)
let targetDPI: CGFloat = 300.0

// Keyline Shape Logic
let contentRect = CGRect(x: 56, y: 66, width: 912, height: 912)
let cornerRadius: CGFloat = 205

// Asset Sizes to Generate
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - Step 1: Bake Mask & Shadow

func refineMasterIcon() {
    print("🎨 Step 1: Baking Squircle Mask and Shadow...")

    guard let nsImage = NSImage(contentsOfFile: inputMasterPath) else {
        print("❌ Could not load input image at \(inputMasterPath)")
        exit(1)
    }

    guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("❌ Could not get CGImage from input.")
        exit(1)
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard
        let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
    else {
        print("❌ Could not create drawing context.")
        exit(1)
    }

    context.clear(CGRect(origin: .zero, size: canvasSize))

    let path = CGPath(
        roundedRect: contentRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
        transform: nil)

    // Draw Shadow
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -12), blur: 25, color: CGColor(gray: 0, alpha: 0.4))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Draw Masked Image
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.draw(cgImage, in: contentRect)
    context.restoreGState()

    guard let resultingImage = context.makeImage() else {
        print("❌ Failed to create resulting image.")
        exit(1)
    }

    let fileURL = URL(fileURLWithPath: maskedMasterPath)
    guard
        let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        print("❌ Failed to create image destination.")
        exit(1)
    }

    let properties =
        [
            kCGImagePropertyDPIWidth: targetDPI,
            kCGImagePropertyDPIHeight: targetDPI,
        ] as [CFString: Any]

    CGImageDestinationAddImage(destination, resultingImage, properties as CFDictionary)
    if CGImageDestinationFinalize(destination) {
        print("✅ Saved Masked Master to: \(maskedMasterPath)")
    } else {
        print("❌ Failed to save masked master.")
        exit(1)
    }
}

// MARK: - Step 2: Generate Asset Sizes

func generateAssetSizes() {
    print("📏 Step 2: Generating Asset Sizes...")

    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: outputDir) {
        print("❌ Output directory does not exist: \(outputDir)")
        exit(1)
    }

    for (filename, size) in sizes {
        let destination = "\(outputDir)/\(filename)"
        resizeImage(at: maskedMasterPath, to: size, destination: destination)
        print("   Generated: \(filename) (\(size)px)")
    }
    print("✅ All assets generated.")
}

func resizeImage(at path: String, to size: Int, destination: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = [
        "-s", "format", "png",
        "-s", "dpiHeight", "300",
        "-s", "dpiWidth", "300",
        "-z", "\(size)", "\(size)",
        path, "--out", destination,
    ]

    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            print("❌ sips exited with status \(task.terminationStatus) for \(destination)")
        }
    } catch {
        print("❌ Error running sips: \(error)")
    }
}

// MARK: - Main Execution

refineMasterIcon()
generateAssetSizes()
print("🎉 App Icon Workflow Completed Successfully!")
