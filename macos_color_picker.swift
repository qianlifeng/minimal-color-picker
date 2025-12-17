// Minimal Color Picker (macOS, single-file)
// Build:
//   swiftc -O macos_color_picker.swift -o color_picker_macos \
//     -framework AppKit -framework CoreGraphics -framework Foundation -framework ScreenCaptureKit
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
// - Screen recording permission is required for ScreenCaptureKit.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - StreamOutput for ScreenCaptureKit

final class StreamOutput: NSObject, SCStreamOutput {
    private let onFrame: (CGImage) -> Void
    private let ciContext = CIContext()
    
    init(onFrame: @escaping (CGImage) -> Void) {
        self.onFrame = onFrame
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let rect = CGRect(x: 0, y: 0,
                          width: CVPixelBufferGetWidth(imageBuffer),
                          height: CVPixelBufferGetHeight(imageBuffer))
        
        guard let cgImage = ciContext.createCGImage(ciImage, from: rect) else { return }
        onFrame(cgImage)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = delegate.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    case .leftMouseDown:
        delegate.pickAndExit()
        return nil
    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        delegate.handleKey(keyCode: Int(keyCode), flags: event.flags)
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

final class MagnifierView: NSView {
    var image: CGImage?
    var borderWidth: CGFloat = 2

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

    fileprivate var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    
    private var scContent: SCShareableContent?
    private var scStream: SCStream?
    private var streamOutput: StreamOutput?
    private var latestFrame: CGImage?
    private let frameQueue = DispatchQueue(label: "minimalColorPicker.latestFrame")
    private var captureDisplayFrame: CGRect = .zero
    private var captureDisplayID: CGDirectDisplayID?
    private let captureSwitchQueue = DispatchQueue(label: "minimalColorPicker.captureSwitch")
    private var isSwitchingCapture: Bool = false

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

        // Place the window near the cursor before showing it to avoid a flash at (0,0).
        positionWindowNearCursor()
        window.makeKeyAndOrderFront(nil)

        // Global input (keyboard + click)
        setupEventTap()

        // Initialize ScreenCaptureKit
        setupScreenCapture()

        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
    }

    private func positionWindowNearCursor() {
        let cursorCocoa = NSEvent.mouseLocation
        let desired = CGPoint(
            x: cursorCocoa.x + offset.x,
            y: cursorCocoa.y - offset.y - radius * 2
        )
        let clamped = clampToVisible(desiredOrigin: desired, size: CGSize(width: radius * 2, height: radius * 2))
        window.setFrameOrigin(clamped)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        scStream?.stopCapture()
        stopEventTap()
    }

    private func setupEventTap() {
        let mask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)
        )

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            print("Failed to create event tap. Ensure Input Monitoring/Accessibility permissions are granted.")
            return
        }

        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let src = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTapSource = nil
        eventTap = nil
    }
    
    private func setupScreenCapture() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                self.scContent = content

                // Start capturing the display under the cursor.
                self.switchCaptureDisplayIfNeeded(force: true)
            } catch {
                print("ScreenCaptureKit error: \(error)")
            }
        }
    }

    private func excludedWindowsForCapture() -> [SCWindow] {
        // When running as a CLI tool, bundleIdentifier may be nil; in that case, don't exclude.
        guard let content = scContent else { return [] }
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        return content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
    }

    private func switchCaptureDisplayIfNeeded(force: Bool = false) {
        guard let content = scContent else { return }
        let cursorQ = currentCursorQuartz()
        guard let display = content.displays.first(where: { $0.frame.contains(cursorQ) }) ?? content.displays.first else { return }

        let newID = display.displayID
        if !force, let currentID = captureDisplayID, currentID == newID {
            return
        }

        var shouldStart = false
        captureSwitchQueue.sync {
            if !isSwitchingCapture {
                isSwitchingCapture = true
                shouldStart = true
            }
        }
        if !shouldStart { return }

        Task {
            defer {
                captureSwitchQueue.sync {
                    isSwitchingCapture = false
                }
            }

            // Stop previous stream (best-effort).
            if let oldStream = scStream {
                do {
                    try await oldStream.stopCapture()
                } catch {
                    // Ignore stop errors; we'll attempt to start a new stream anyway.
                }
            }
            scStream = nil

            // Clear stale frame so we don't crop against the wrong display.
            frameQueue.sync {
                latestFrame = nil
            }

            captureDisplayFrame = display.frame
            captureDisplayID = newID

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindowsForCapture())
            let config = SCStreamConfiguration()
            config.width = max(1, display.width)
            config.height = max(1, display.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            scStream = stream

            let output: StreamOutput
            if let existing = streamOutput {
                output = existing
            } else {
                output = StreamOutput { [weak self] image in
                    self?.frameQueue.async {
                        self?.latestFrame = image
                    }
                }
                streamOutput = output
            }

            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global())
                try await stream.startCapture()
            } catch {
                print("ScreenCaptureKit startCapture error: \(error)")
            }
        }
    }

    fileprivate func handleKey(keyCode: Int, flags: CGEventFlags) {
        let step: CGFloat = flags.contains(.maskShift) ? 5 : 1
        let loc = currentCursorQuartz() // global, origin top-left

        var dx: CGFloat = 0
        var dy: CGFloat = 0

        switch keyCode {
        case 36, 76: // return, keypad enter
            pickAndExit()
            return
        case 123: dx = -step // left
        case 124: dx = step  // right
        case 125: dy = step  // down (Quartz y+ is down)
        case 126: dy = -step // up
        case 53:
            exitCleanly()
            return
        default:
            return
        }

        let newPoint = CGPoint(x: loc.x + dx, y: loc.y + dy)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        CGWarpMouseCursorPosition(newPoint)
    }

    private func currentCursorQuartz() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func updateFrame() {
        // Always move the window even if capture/frame isn't ready.
        positionWindowNearCursor()

        // If the cursor moved to another display, switch the capture stream.
        switchCaptureDisplayIfNeeded()

        let capSize = odd(Int((radius * 2) / zoom))
        let half = CGFloat(capSize / 2)

        // Get the latest captured frame
        let fullFrame = frameQueue.sync { latestFrame }
        
        guard let fullFrame = fullFrame else { return }

        // Crop in the captured display's logical coordinate system (origin top-left).
        let cursorQ = currentCursorQuartz()
        let relX = cursorQ.x - captureDisplayFrame.origin.x
        let relY = cursorQ.y - captureDisplayFrame.origin.y

        var cropRect = CGRect(x: relX - half, y: relY - half, width: CGFloat(capSize), height: CGFloat(capSize))
        cropRect = cropRect.integral

        // Clamp to image bounds to avoid nil cropping.
        let imgBounds = CGRect(x: 0, y: 0, width: fullFrame.width, height: fullFrame.height)
        let clippedRect = cropRect.intersection(imgBounds)
        guard !clippedRect.isEmpty, let croppedImage = fullFrame.cropping(to: clippedRect) else { return }

        // Scale up by drawing into a new bitmap at window size.
        let dstW = Int(radius * 2)
        let dstH = Int(radius * 2)
        guard let scaled = scaleNearest(src: croppedImage, dstWidth: dstW, dstHeight: dstH) else { return }

        view.image = scaled
        view.needsDisplay = true
    }

    fileprivate func pickAndExit() {
        let cursorQ = currentCursorQuartz()
        let relX = cursorQ.x - captureDisplayFrame.origin.x
        let relY = cursorQ.y - captureDisplayFrame.origin.y

        let fullFrame = frameQueue.sync { latestFrame }

        guard let fullFrame = fullFrame else {
            exitCleanly()
            return
        }

        let imgBounds = CGRect(x: 0, y: 0, width: fullFrame.width, height: fullFrame.height)
        let sampleRect = CGRect(x: relX, y: relY, width: 1, height: 1).intersection(imgBounds)
        guard !sampleRect.isEmpty,
              let croppedImage = fullFrame.cropping(to: sampleRect),
              let color = sampleTopLeftPixel(croppedImage) else {
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
        timer?.invalidate(); timer = nil
        scStream?.stopCapture()
        stopEventTap()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

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

extension AppDelegate: @unchecked Sendable {}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
