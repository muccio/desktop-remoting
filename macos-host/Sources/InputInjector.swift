import Foundation
import CoreGraphics
import AppKit

/// Gestisce l'iniezione degli eventi mouse e tastiera in macOS tramite CGEvent
public final class InputInjector {
    public static let shared = InputInjector()

    private init() {}

    /// Verifica se l'applicazione dispone dei permessi di Accessibilità necessari per inviare CGEvent
    public func checkAccessibilityPermissions(promptIfNeeded: Bool = true) -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Esegue il parsing e l'iniezione di un comando JSON ricevuto via WebRTC DataChannel
    public func handleInputJsonString(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let type = dict["type"] as? String else {
                return
            }
            handleCommand(type: type, payload: dict)
        } catch {
            print("[InputInjector] Errore deserializzazione JSON evento: \(error)")
        }
    }

    private func handleCommand(type: String, payload: [String: Any]) {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame
        let screenWidth = screenRect.width
        let screenHeight = screenRect.height

        switch type {
        case "mouse_move":
            if let normX = payload["x"] as? Double, let normY = payload["y"] as? Double {
                let targetX = CGFloat(normX) * screenWidth
                // In macOS l'origine dello schermo (0,0) per CGEvent è in alto a sinistra
                let targetY = CGFloat(normY) * screenHeight
                injectMouseMove(to: CGPoint(x: targetX, y: targetY))
            }

        case "mouse_move_rel":
            let dx = (payload["dx"] as? Double) ?? 0.0
            let dy = (payload["dy"] as? Double) ?? 0.0
            injectMouseMoveRelative(dx: CGFloat(dx), dy: CGFloat(dy))

        case "mouse_click":
            let button = (payload["button"] as? String) ?? "left"
            let doubleClick = (payload["double"] as? Bool) ?? false
            injectMouseClick(button: button, doubleClick: doubleClick)

        case "mouse_down":
            if let normX = payload["x"] as? Double,
               let normY = payload["y"] as? Double {
                let targetX = CGFloat(normX) * screenWidth
                let targetY = CGFloat(normY) * screenHeight
                let button = (payload["button"] as? String) ?? "left"
                injectMouseDown(at: CGPoint(x: targetX, y: targetY), button: button)
            }

        case "mouse_up":
            if let normX = payload["x"] as? Double,
               let normY = payload["y"] as? Double {
                let targetX = CGFloat(normX) * screenWidth
                let targetY = CGFloat(normY) * screenHeight
                let button = (payload["button"] as? String) ?? "left"
                injectMouseUp(at: CGPoint(x: targetX, y: targetY), button: button)
            }

        case "mouse_scroll":
            let dx = (payload["dx"] as? Double) ?? 0.0
            let dy = (payload["dy"] as? Double) ?? 0.0
            injectScroll(dx: Int32(dx), dy: Int32(dy))

        case "key_down":
            if let keyCode = payload["keyCode"] as? UInt16 {
                injectKeyEvent(keyCode: keyCode, isDown: true)
            }

        case "key_up":
            if let keyCode = payload["keyCode"] as? UInt16 {
                injectKeyEvent(keyCode: keyCode, isDown: false)
            }

        case "text_input":
            if let text = payload["text"] as? String {
                injectTextInput(text: text)
            }

        default:
            print("[InputInjector] Comando non supportato: \(type)")
        }
    }

    // MARK: - Primitivi Core Graphics Event

    public func injectMouseMove(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    /// Muove il cursore in modo relativo rispetto alla posizione attuale (come un trackpad fisico)
    public func injectMouseMoveRelative(dx: CGFloat, dy: CGFloat) {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let currentLoc = currentEvent.location
        let screenBounds = CGDisplayBounds(CGMainDisplayID())
        let newX = max(0, min(screenBounds.width - 1, currentLoc.x + dx))
        let newY = max(0, min(screenBounds.height - 1, currentLoc.y + dy))
        let newPoint = CGPoint(x: newX, y: newY)

        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: newPoint, mouseButton: .left) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    /// Esegue un click (singolo o doppio) alla posizione attuale del cursore
    public func injectMouseClick(button: String = "left", doubleClick: Bool = false) {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let point = currentEvent.location
        let downType: CGEventType = (button == "right") ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = (button == "right") ? .rightMouseUp : .leftMouseUp
        let mouseButton: CGMouseButton = (button == "right") ? .right : .left

        let clicks = doubleClick ? 2 : 1
        for i in 1...clicks {
            if let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton) {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton) {
                up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                up.post(tap: .cghidEventTap)
            }
        }
    }

    public func injectMouseDown(at point: CGPoint, button: String = "left") {
        let mouseType: CGEventType = (button == "right") ? .rightMouseDown : .leftMouseDown
        let mouseButton: CGMouseButton = (button == "right") ? .right : .left

        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    public func injectMouseUp(at point: CGPoint, button: String = "left") {
        let mouseType: CGEventType = (button == "right") ? .rightMouseUp : .leftMouseUp
        let mouseButton: CGMouseButton = (button == "right") ? .right : .left

        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    public func injectScroll(dx: Int32, dy: Int32) {
        // scrollWheelEvent2Source accetta pixel o linee
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    public func injectKeyEvent(keyCode: UInt16, isDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    public func injectTextInput(text: String) {
        let utf16Chars = Array(text.utf16)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            return
        }
        event.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
        event.post(tap: .cghidEventTap)
    }
}
