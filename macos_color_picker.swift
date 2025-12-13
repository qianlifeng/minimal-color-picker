// Minimal Color Picker (macOS, single-file)
// Build:
//   swiftc -O macos_color_picker.swift -o color_picker_macos \
//     -framework AppKit -framework CoreGraphics -framework Foundation
// Run:
//   ./color_picker_macos
//
// Behavior:
// - Shows a circular magnifier near the cursor.
// - Left click: copies center pixel color as #RRGGBB to clipboard and exits.
// - Arrow keys: nudge cursor by 1px (Shift for 5px). Esc exits.
//
// Notes:
// - On recent macOS versions, global mouse/key monitoring may require
//   enabling "Input Monitoring" for the terminal/app.

import AppKit
import CoreGraphics
import Foundation

final class MagnifierView: NSView {
    var image: CGImage?
    var borderWidth: CGFloat = 2

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let radius = min(bounds.width, bounds.height) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        ctx.clear(bounds)

        // Clip to circle
        ctx.saveGState()
        let circle = CGPath(ellipseIn: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), transform: nil)
        ctx.addPath(circle)
        ctx.clip()

        if let img = image {
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            ctx.draw(img, in: bounds)
        }
        ctx.restoreGState()

        // Border
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(borderWidth)
        ctx.strokeEllipse(in: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))

        // Center marker (small square)
        let m: CGFloat = 6
        let marker = CGRect(x: center.x - m/2, y: center.y - m/2, width: m, height: m)
        ctx.setFillColor(NSColor.clear.cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(marker)

        // Optional subtle crosshair? (Not requested) -> omit
        _ = radius
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let radius: CGFloat = 120
    private let zoom: CGFloat = 8
    private let tick: TimeInterval = 1.0 / 60.0
    private let offset = CGPoint(x: 40, y: 40)

    private var window: NSWindow!
    private var view: MagnifierView!
    private var timer: Timer?

    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let size = NSSize(width: radius * 2, height: radius * 2)
        let rect = NSRect(origin: .zero, size: size)

        window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true

        view = MagnifierView(frame: rect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        // Global monitors
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.pickAndExit()
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKey(event)
        }

        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let k = globalKeyMonitor { NSEvent.removeMonitor(k) }
        timer?.invalidate()
    }

    private func handleKey(_ event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 5 : 1
        let loc = NSEvent.mouseLocation // global, origin bottom-left

        var dx: CGFloat = 0
        var dy: CGFloat = 0

        switch event.keyCode {
        case 36, 76: // return, keypad enter
            pickAndExit()
            return
        case 123: dx = -step // left
        case 124: dx = step  // right
        case 125: dy = -step // down
        case 126: dy = step  // up
        case 53:  exitCleanly() // esc
        default: return
        }

        let newPoint = CGPoint(x: loc.x + dx, y: loc.y + dy)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        CGWarpMouseCursorPosition(newPoint)
    }

    private func updateFrame() {
        let cursor = NSEvent.mouseLocation
        let capSize = odd(Int((radius * 2) / zoom))
        let half = CGFloat(capSize / 2)

        let srcRectCocoa = CGRect(x: cursor.x - half, y: cursor.y - half, width: CGFloat(capSize), height: CGFloat(capSize))
        guard let cg = capture(rectCocoa: srcRectCocoa) else { return }

        // Scale up by drawing into a new bitmap at window size.
        let dstW = Int(radius * 2)
        let dstH = Int(radius * 2)
        guard let scaled = scaleNearest(src: cg, dstWidth: dstW, dstHeight: dstH) else { return }

        view.image = scaled
        view.needsDisplay = true

        // Position window near cursor (convert to screen with origin bottom-left)
        // Window coordinates use bottom-left origin in global.
        let desired = CGPoint(x: cursor.x + offset.x, y: cursor.y - offset.y - radius * 2) // y: place below-right in Cocoa coords
        let clamped = clampToVisible(desiredOrigin: desired, size: CGSize(width: radius * 2, height: radius * 2))
        window.setFrameOrigin(clamped)
    }

    private func pickAndExit() {
        let cursor = NSEvent.mouseLocation
        let srcRect = CGRect(x: cursor.x, y: cursor.y, width: 1, height: 1)
        guard let cg = capture(rectCocoa: srcRect),
              let color = sampleTopLeftPixel(cg) else {
            exitCleanly()
            return
        }

        let hex = String(format: "#%02X%02X%02X", color.r, color.g, color.b)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hex, forType: .string)

        print(hex)
        fflush(stdout)

        exitCleanly()
    }

    private func exitCleanly() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let k = globalKeyMonitor { NSEvent.removeMonitor(k); globalKeyMonitor = nil }
        timer?.invalidate(); timer = nil
        NSApp.terminate(nil)
    }

    // MARK: - Capture helpers

    private func capture(rectCocoa: CGRect) -> CGImage? {
        // Convert Cocoa global coords (origin bottom-left, y up)
        // to Quartz global display coords (origin top-left of main display, y down).
        let mainH = CGDisplayBounds(CGMainDisplayID()).height

        let qx = rectCocoa.origin.x
        let qy = mainH - (rectCocoa.origin.y + rectCocoa.size.height)
        let qRect = CGRect(x: qx, y: qy, width: rectCocoa.width, height: rectCocoa.height)

        return CGWindowListCreateImage(qRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    private func scaleNearest(src: CGImage, dstWidth: Int, dstHeight: Int) -> CGImage? {
        guard let cs = src.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: dstWidth,
            height: dstHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: dstWidth, height: dstHeight))
        return ctx.makeImage()
    }

    private struct RGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private func sampleTopLeftPixel(_ img: CGImage) -> RGB? {
        guard let data = img.dataProvider?.data else { return nil }
        let ptr = CFDataGetBytePtr(data)
        guard let ptr else { return nil }

        // CGWindowListCreateImage typically returns BGRA (byte order varies).
        // We’ll handle the common 32bpp BGRA case.
        if img.bitsPerPixel >= 32 {
            let b = ptr[0]
            let g = ptr[1]
            let r = ptr[2]
            return RGB(r: r, g: g, b: b)
        }
        return nil
    }

    private func clampToVisible(desiredOrigin: CGPoint, size: CGSize) -> CGPoint {
        // Clamp to visible frame of the screen containing the cursor if possible.
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var x = desiredOrigin.x
        var y = desiredOrigin.y

        if x < visible.minX { x = visible.minX }
        if y < visible.minY { y = visible.minY }
        if x + size.width > visible.maxX { x = visible.maxX - size.width }
        if y + size.height > visible.maxY { y = visible.maxY - size.height }

        return CGPoint(x: x, y: y)
    }

    private func odd(_ n: Int) -> Int { (n % 2 == 0) ? (n + 1) : n }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
