import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Gestore centralizzato dei permessi macOS (Screen Recording e Accessibilità)
public final class PermissionsManager {
    public static let shared = PermissionsManager()

    private init() {}

    /// Verifica se i permessi di registrazione schermo sono concessi
    public var isScreenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Richiede al sistema operativo i permessi di registrazione schermo aprendo il popup di sistema
    public func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Verifica se i permessi di accessibilità (CGEvent) sono concessi
    public var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Richiede al sistema operativo i permessi di accessibilità aprendo il popup di sistema
    public func requestAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Apre la sezione Registrazione Schermo e Audio di Sistema nelle Impostazioni di Sistema macOS
    public func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Apre la sezione Accessibilità nelle Impostazioni di Sistema macOS
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Riavvia l'applicazione per forzare l'aggiornamento della cache TCC di macOS
    public func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
