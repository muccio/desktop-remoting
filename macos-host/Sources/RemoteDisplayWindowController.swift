import Cocoa
import AVFoundation
import CoreMedia
import SwiftUI

/// Window Controller per la visualizzazione a schermo intero e il controllo a bassissima latenza
public final class RemoteDisplayWindowController: NSWindowController, NSWindowDelegate {
    public static var current: RemoteDisplayWindowController?

    private let client: LANStreamClient
    private var displayView: RemoteDisplayView?

    public init(client: LANStreamClient = .shared) {
        self.client = client

        // Crea una finestra borderless / full-size adatta sia a finestra normale sia a Fullscreen nativo
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialWidth = min(screenRect.width * 0.85, 1920)
        let initialHeight = min(screenRect.height * 0.85, 1080)
        let initialRect = NSRect(
            x: (screenRect.width - initialWidth) / 2,
            y: (screenRect.height - initialHeight) / 2,
            width: initialWidth,
            height: initialHeight
        )

        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Schermo Remoto LAN - Ultra Low Latency"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.acceptsMouseMovedEvents = true

        super.init(window: window)
        window.delegate = self

        let view = RemoteDisplayView(client: client, windowController: self)
        window.contentView = view
        self.displayView = view

        RemoteDisplayWindowController.current = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supportato")
    }

    public static func showWindow(client: LANStreamClient = .shared) {
        if let existing = current, existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = RemoteDisplayWindowController(client: client)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        displayView?.cleanup()
        client.disconnect()
        RemoteDisplayWindowController.current = nil
    }

    public func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }
}

/// View nativa AppKit ottimizzata per rendering GPU H.264 immediato e cattura eventi mouse/tastiera
public final class RemoteDisplayView: NSView {
    private let client: LANStreamClient
    private weak var windowController: RemoteDisplayWindowController?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var trackingArea: NSTrackingArea?

    // HUD / Overlay di stato e controlli
    private var hudContainer: NSView?
    private var statsLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var disconnectButton: NSButton?
    private var fullscreenButton: NSButton?
    private var hudTrackingArea: NSTrackingArea?
    private var hudTimer: Timer?

    public init(client: LANStreamClient, windowController: RemoteDisplayWindowController) {
        self.client = client
        self.windowController = windowController
        super.init(frame: .zero)

        setupDisplayLayer()
        setupHUD()
        setupCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non supportato")
    }

    private func setupDisplayLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        layer?.addSublayer(displayLayer)
    }

    private func setupCallbacks() {
        client.onSampleBufferReceived = { [weak self] sampleBuffer in
            DispatchQueue.main.async {
                self?.enqueueSampleBuffer(sampleBuffer)
            }
        }
    }

    private func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            print("[RemoteDisplayView] DisplayLayer status failed: errore \(String(describing: displayLayer.error)). Ripristino...")
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
        updateHUDStats()
    }

    public func cleanup() {
        client.onSampleBufferReceived = nil
        displayLayer.stopRequestingMediaData()
        displayLayer.flush()
        hudTimer?.invalidate()
    }

    public override func layout() {
        super.layout()
        displayLayer.frame = bounds
        layoutHUD()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    // MARK: - Calcolo Rettangolo Video & Coordinate Normalizzate

    /// Calcola la regione esatta di visualizzazione del desktop trasmesso (mantenendo l'aspect ratio)
    public func activeVideoRect() -> CGRect {
        let viewWidth = bounds.width
        let viewHeight = bounds.height
        guard viewWidth > 0, viewHeight > 0 else { return bounds }

        var videoWidth: CGFloat = 1920
        var videoHeight: CGFloat = 1080

        if let formatDesc = client.currentFormatDescription {
            let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
            if dims.width > 0 && dims.height > 0 {
                videoWidth = CGFloat(dims.width)
                videoHeight = CGFloat(dims.height)
            }
        }

        let videoAspect = videoWidth / videoHeight
        let viewAspect = viewWidth / viewHeight

        var renderWidth: CGFloat
        var renderHeight: CGFloat
        var originX: CGFloat
        var originY: CGFloat

        if viewAspect > videoAspect {
            // Finestra più larga del video: barre nere laterali
            renderHeight = viewHeight
            renderWidth = viewHeight * videoAspect
            originX = (viewWidth - renderWidth) / 2.0
            originY = 0.0
        } else {
            // Finestra più alta del video: barre nere sopra/sotto
            renderWidth = viewWidth
            renderHeight = viewWidth / videoAspect
            originX = 0.0
            originY = (viewHeight - renderHeight) / 2.0
        }

        return CGRect(x: originX, y: originY, width: renderWidth, height: renderHeight)
    }

    /// Converte le coordinate dell'evento del mouse locale dell'iMac in coordinate normalizzate (0.0...1.0)
    /// Con inversione asse Y (0.0 in alto, 1.0 in basso) per corrispondere allo standard macOS CGEvent dell'Host.
    private func normalizedCoordinates(from event: NSEvent) -> (normX: Double, normY: Double)? {
        let loc = convert(event.locationInWindow, from: nil)
        let rect = activeVideoRect()
        guard rect.width > 0 && rect.height > 0 else { return nil }

        // Blocca con clamping così da consentire di raggiungere pixel Menu Bar e Dock anche se il cursore oltrepassa di 1px
        let clampedX = max(rect.minX, min(rect.maxX, loc.x))
        let clampedY = max(rect.minY, min(rect.maxY, loc.y))

        let normX = Double((clampedX - rect.minX) / rect.width)
        let normY = 1.0 - Double((clampedY - rect.minY) / rect.height)

        return (normX: max(0.0, min(1.0, normX)), normY: max(0.0, min(1.0, normY)))
    }

    // MARK: - Gestione Eventi Mouse

    public override func mouseMoved(with event: NSEvent) {
        checkHUDHover(event)
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_move",
            "x": nx,
            "y": ny
        ])
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }

        if event.clickCount == 2 {
            client.sendInputEvent([
                "type": "mouse_click",
                "button": "left",
                "double": true
            ])
        } else {
            client.sendInputEvent([
                "type": "mouse_down",
                "x": nx,
                "y": ny,
                "button": "left"
            ])
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_up",
            "x": nx,
            "y": ny,
            "button": "left"
        ])
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_drag",
            "x": nx,
            "y": ny,
            "button": "left"
        ])
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_down",
            "x": nx,
            "y": ny,
            "button": "right"
        ])
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_up",
            "x": nx,
            "y": ny,
            "button": "right"
        ])
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_drag",
            "x": nx,
            "y": ny,
            "button": "right"
        ])
    }

    public override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_down",
            "x": nx,
            "y": ny,
            "button": "other"
        ])
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_up",
            "x": nx,
            "y": ny,
            "button": "other"
        ])
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard let (nx, ny) = normalizedCoordinates(from: event) else { return }
        client.sendInputEvent([
            "type": "mouse_drag",
            "x": nx,
            "y": ny,
            "button": "other"
        ])
    }

    public override func scrollWheel(with event: NSEvent) {
        // Usa scrollingDelta con precisione pixel per scrolling fluidissimo
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 10
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10

        client.sendInputEvent([
            "type": "mouse_scroll",
            "dx": Double(dx),
            "dy": Double(dy)
        ])
    }

    // MARK: - Gestione Eventi Tastiera

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Scorciatoia di emergenza per uscire da schermo intero: Ctrl + Shift + Esc
        if event.modifierFlags.contains([.control, .shift]) && event.keyCode == 53 {
            windowController?.toggleFullscreen()
            return
        }

        client.sendInputEvent([
            "type": "key_down",
            "keyCode": event.keyCode,
            "flags": event.modifierFlags.rawValue
        ])
    }

    public override func keyUp(with event: NSEvent) {
        client.sendInputEvent([
            "type": "key_up",
            "keyCode": event.keyCode,
            "flags": event.modifierFlags.rawValue
        ])
    }

    public override func flagsChanged(with event: NSEvent) {
        // Intercetta tasti modificatori (Cmd, Option, Shift, Control)
        let keyCode = event.keyCode
        let isPressed: Bool
        switch keyCode {
        case 54, 55: // Command (Destro, Sinistro)
            isPressed = event.modifierFlags.contains(.command)
        case 56, 60: // Shift (Sinistro, Destro)
            isPressed = event.modifierFlags.contains(.shift)
        case 58, 61: // Option (Sinistro, Destro)
            isPressed = event.modifierFlags.contains(.option)
        case 59, 62: // Control (Sinistro, Destro)
            isPressed = event.modifierFlags.contains(.control)
        case 57: // Caps Lock
            isPressed = event.modifierFlags.contains(.capsLock)
        default:
            isPressed = false
        }

        client.sendInputEvent([
            "type": isPressed ? "key_down" : "key_up",
            "keyCode": keyCode,
            "flags": event.modifierFlags.rawValue
        ])
    }

    // MARK: - HUD e Barra Informazioni Scomparsa

    private func setupHUD() {
        let hud = NSView()
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        hud.layer?.cornerRadius = 10
        hud.layer?.masksToBounds = true
        hud.alphaValue = 0.0 // Nascosto di default, appare su hover in alto

        let status = NSTextField(labelWithString: "LAN Stream Client")
        status.font = .systemFont(ofSize: 12, weight: .bold)
        status.textColor = .white
        hud.addSubview(status)
        self.statusLabel = status

        let stats = NSTextField(labelWithString: "In attesa stream...")
        stats.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        stats.textColor = NSColor.systemGreen
        hud.addSubview(stats)
        self.statsLabel = stats

        let fsBtn = NSButton(title: "Schermo Intero", target: self, action: #selector(didClickFullscreen))
        fsBtn.bezelStyle = .inline
        fsBtn.font = .systemFont(ofSize: 11)
        hud.addSubview(fsBtn)
        self.fullscreenButton = fsBtn

        let discBtn = NSButton(title: "Chiudi", target: self, action: #selector(didClickDisconnect))
        discBtn.bezelStyle = .inline
        discBtn.font = .systemFont(ofSize: 11)
        hud.addSubview(discBtn)
        self.disconnectButton = discBtn

        addSubview(hud)
        self.hudContainer = hud
    }

    private func layoutHUD() {
        guard let hud = hudContainer else { return }
        let hudWidth: CGFloat = 460
        let hudHeight: CGFloat = 36
        hud.frame = NSRect(
            x: (bounds.width - hudWidth) / 2,
            y: bounds.height - hudHeight - 12,
            width: hudWidth,
            height: hudHeight
        )

        statusLabel?.frame = NSRect(x: 14, y: 10, width: 140, height: 16)
        statsLabel?.frame = NSRect(x: 160, y: 10, width: 150, height: 16)
        fullscreenButton?.frame = NSRect(x: 315, y: 7, width: 75, height: 22)
        disconnectButton?.frame = NSRect(x: 395, y: 7, width: 50, height: 22)
    }

    private func checkHUDHover(_ event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // Se il cursore si avvicina al bordo superiore (ultimi 60 pixel), mostra l'HUD
        let isNearTop = loc.y >= bounds.height - 60
        if isNearTop {
            showHUD()
        } else {
            hideHUDDelayed()
        }
    }

    private func showHUD() {
        hudTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.hudContainer?.animator().alphaValue = 1.0
        }
    }

    private func hideHUDDelayed() {
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.hudContainer?.animator().alphaValue = 0.0
            }
        }
    }

    private func updateHUDStats() {
        let fps = client.currentFPS
        let mbps = client.currentBitrateMbps
        let res = client.videoResolution
        let resStr = res.width > 0 ? "\(Int(res.width))x\(Int(res.height))" : "--"
        statsLabel?.stringValue = String(format: "%.0f FPS • %.1f Mbps • %@", fps, mbps, resStr)
    }

    @objc private func didClickFullscreen() {
        windowController?.toggleFullscreen()
    }

    @objc private func didClickDisconnect() {
        window?.close()
    }
}
