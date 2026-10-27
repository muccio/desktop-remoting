import SwiftUI
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] Applicazione in chiusura: rilascio stato sleep...")
        SleepPreventer.shared.restoreAllSynchronous()
    }
}

@main
struct HostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = HostViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 540, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - ViewModel
@MainActor
final class HostViewModel: ObservableObject, ScreenCaptureManagerDelegate, WebRTCManagerDelegate {
    @Published var serverUrl: String = "https://mariosalvucci.com/backend-php/"
    @Published var macId: String = Host.current().localizedName ?? "mac-remote-host"
    @Published var targetFps: Int = 60
    @Published var selectedResolution: CaptureResolution = .fhd1080
    @Published var statusMessage: String = "Pronto all'avvio"
    @Published var isRunning: Bool = false

    @Published var isScreenCaptureGranted: Bool = false
    @Published var isAccessibilityGranted: Bool = false

    // Prevenzione Sleep e Coperchio Chiuso (Clamshell)
    @Published var keepLidCloseAwake: Bool = true
    @ObservedObject var sleepPreventer = SleepPreventer.shared

    private let screenCaptureManager = ScreenCaptureManager()
    nonisolated private let webRTCManager = WebRTCManager()
    private var monitorTimer: Timer?

    init() {
        screenCaptureManager.delegate = self
        webRTCManager.delegate = self
        checkPermissions()
        startPermissionMonitoring()
    }

    func checkPermissions() {
        isScreenCaptureGranted = PermissionsManager.shared.isScreenCaptureGranted
        isAccessibilityGranted = PermissionsManager.shared.isAccessibilityGranted
    }

    func startPermissionMonitoring() {
        checkPermissions()
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissions()
            }
        }
    }

    func requestScreenCapture() {
        PermissionsManager.shared.requestScreenCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PermissionsManager.shared.openScreenCaptureSettings()
            self.checkPermissions()
        }
    }

    func requestAccessibility() {
        PermissionsManager.shared.requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PermissionsManager.shared.openAccessibilitySettings()
            self.checkPermissions()
        }
    }

    func relaunchApp() {
        PermissionsManager.shared.relaunchApp()
    }

    func startHost() {
        guard let url = URL(string: serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            statusMessage = "URL Server non valido"
            return
        }

        checkPermissions()

        if !isScreenCaptureGranted {
            statusMessage = "Permesso Registrazione Schermo mancante!"
            requestScreenCapture()
            return
        }

        if !isAccessibilityGranted {
            requestAccessibility()
        }

        isRunning = true
        statusMessage = "Inizializzazione cattura schermo e WebRTC..."

        // Attiva la prevenzione della sospensione (Idle + Display + opzionale Lid-Close)
        SleepPreventer.shared.startPrevention(preventLidClose: keepLidCloseAwake)

        Task {
            do {
                try await screenCaptureManager.startCapture(targetFps: targetFps, resolution: selectedResolution)
                webRTCManager.startHostSession(serverBaseUrl: url, macId: macId)
            } catch {
                statusMessage = "Errore avvio: \(error.localizedDescription)"
                isRunning = false
                SleepPreventer.shared.stopPrevention()
            }
        }
    }

    func stopHost() {
        isRunning = false
        isRestartingHost = false
        statusMessage = "Arresto in corso..."

        // Rilascia le asserzioni di sospensione e ripristina pmset
        SleepPreventer.shared.stopPrevention()

        let url = URL(string: serverUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        webRTCManager.stopSession(serverBaseUrl: url, macId: macId)

        Task {
            await screenCaptureManager.stopCapture()
            statusMessage = "Host disconnesso."
        }
    }

    /// Aggiorna la modalità coperchio chiuso anche a sessione in corso
    func updateLidCloseAwakeToggle(_ enabled: Bool) {
        keepLidCloseAwake = enabled
        if isRunning {
            if enabled {
                SleepPreventer.shared.enableLidCloseSleepPrevention()
            } else {
                SleepPreventer.shared.disableLidCloseSleepPrevention()
            }
        }
    }

    private var isRestartingHost: Bool = false

    /// Riavvia completamente la pipeline del server (ScreenCaptureKit + WebRTC) alla disconnessione del client
    func restartHost(reason: String) {
        guard isRunning else { return }
        guard !isRestartingHost else { return }
        isRestartingHost = true

        statusMessage = "Client disconnesso (\(reason)). Riavvio del server in corso..."

        let url = URL(string: serverUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        webRTCManager.stopSession(serverBaseUrl: url, macId: macId)

        Task {
            await screenCaptureManager.stopCapture()

            // Pausa di 600ms per consentire il rilascio completo di stream, encoder e socket
            try? await Task.sleep(nanoseconds: 600_000_000)

            guard self.isRunning else {
                self.isRestartingHost = false
                return
            }

            self.statusMessage = "Riavvio acquisizione e offerta WebRTC in corso..."
            do {
                try await self.screenCaptureManager.startCapture(targetFps: self.targetFps, resolution: self.selectedResolution)
                if let validUrl = url {
                    self.webRTCManager.startHostSession(serverBaseUrl: validUrl, macId: self.macId)
                }
                self.isRestartingHost = false
            } catch {
                self.statusMessage = "Errore riavvio host: \(error.localizedDescription)"
                self.isRestartingHost = false
            }
        }
    }

    // MARK: - ScreenCaptureManagerDelegate
    nonisolated func didCaptureVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        webRTCManager.sendVideoFrame(pixelBuffer, timestamp: timestamp)
    }

    nonisolated func didCaptureAudioSample(_ sampleBuffer: CMSampleBuffer) {
        // Opzionale: inoltro audio alla traccia WebRTC
    }

    // MARK: - WebRTCManagerDelegate
    nonisolated func webRTCStatusDidChange(_ status: String) {
        Task { @MainActor in
            self.statusMessage = status
        }
    }

    nonisolated func webRTCClientConnected() {
        Task { @MainActor in
            self.statusMessage = "Client Mobile Connesso (Streaming attivo)"
        }
    }

    nonisolated func webRTCClientDisconnected() {
        Task { @MainActor in
            self.statusMessage = "Client Mobile Disconnesso"
        }
    }

    nonisolated func webRTCRequestHostRestart(reason: String) {
        Task { @MainActor in
            self.restartHost(reason: reason)
        }
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @ObservedObject var model: HostViewModel

    var allPermissionsGranted: Bool {
        model.isScreenCaptureGranted && model.isAccessibilityGranted
    }

    var body: some View {
        VStack(spacing: 18) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "display.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("macOS Remote Desktop Host")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("ScreenCaptureKit + VideoToolbox + WebRTC (Signaling CSV)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 4)

            Divider()

            // Configuration Form
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL Server PHP (Signaling):")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    TextField("http://tuo-dominio.it/backend-php", text: $model.serverUrl)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Identificativo Mac (mac_id):")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        TextField("es. mac-studio-01", text: $model.macId)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isRunning)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frame Rate Target:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Picker("", selection: $model.targetFps) {
                            Text("30 FPS").tag(30)
                            Text("60 FPS (Smooth)").tag(60)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Risoluzione Trasmessa (Scaling Desktop):")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Picker("", selection: $model.selectedResolution) {
                        ForEach(CaptureResolution.allCases) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }
            }

            // Box Permessi di Sistema macOS
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Permessi di Sistema macOS")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: {
                        model.checkPermissions()
                    }) {
                        Label("Ricarica", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }

                // 1. Registrazione Schermo
                HStack {
                    Image(systemName: model.isScreenCaptureGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(model.isScreenCaptureGranted ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Registrazione Schermo (ScreenCaptureKit)")
                            .font(.footnote)
                            .fontWeight(.semibold)
                        Text(model.isScreenCaptureGranted ? "Flusso video abilitato correttamente" : "Richiesto per acquisire il desktop")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !model.isScreenCaptureGranted {
                        Button("Abilita in Impostazioni") {
                            model.requestScreenCapture()
                        }
                        .font(.caption)
                    }
                }

                Divider()

                // 2. Accessibilità
                HStack {
                    Image(systemName: model.isAccessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(model.isAccessibilityGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Controllo Accessibilità (Mouse e Tastiera CGEvent)")
                            .font(.footnote)
                            .fontWeight(.semibold)
                        Text(model.isAccessibilityGranted ? "Iniezione input abilitata" : "Richiesto per controllare mouse e tastiera")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !model.isAccessibilityGranted {
                        Button("Abilita in Impostazioni") {
                            model.requestAccessibility()
                        }
                        .font(.caption)
                    }
                }

                // Avviso e Pulsante di Riavvio se le modifiche non sono ancora propagate
                if !allPermissionsGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ℹ️ Nota: se hai appena attivato la spunta in Impostazioni di Sistema, macOS richiede il riavvio dell'applicazione per aggiornare i permessi del processo.")
                            .font(.caption2)
                            .foregroundColor(.orange)

                        Button(action: {
                            model.relaunchApp()
                        }) {
                            Label("Riavvia Applicazione", systemImage: "power")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            // Box Gestione Sospensione e Chiusura Coperchio (Clamshell)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "powersleep")
                        .foregroundColor(.indigo)
                    Text("Gestione Sospensione & Coperchio Chiuso")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Spacer()

                    // Badge di Stato Visivo
                    if model.isRunning {
                        if model.sleepPreventer.isLidCloseSleepPrevented {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 11))
                                Text("Lid-Close Awake: ATTIVO")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.18))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                        } else if model.sleepPreventer.isDisplaySleepPrevented || model.sleepPreventer.isIdleSleepPrevented {
                            HStack(spacing: 4) {
                                Image(systemName: "display")
                                    .font(.system(size: 11))
                                Text("Display Awake: ATTIVO")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.18))
                            .foregroundColor(.blue)
                            .cornerRadius(6)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 6, height: 6)
                            Text("Awake: Inattivo")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle("Mantieni attivo a coperchio chiuso (Lid-Close Clamshell)", isOn: Binding(
                    get: { model.keepLidCloseAwake },
                    set: { model.updateLidCloseAwakeToggle($0) }
                ))
                .font(.footnote)
                .fontWeight(.semibold)

                Text("Impedisce la sospensione del MacBook quando il coperchio viene chiuso fisicamente senza monitor esterno (`pmset disablesleep 1`). Il flusso ScreenCaptureKit e la connessione WebRTC rimangono sempre attivi.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isRunning && model.sleepPreventer.isLidCloseSleepPrevented {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Puoi chiudere il coperchio del MacBook in sicurezza: lo streaming continuerà a funzionare.")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .fontWeight(.medium)
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            // Stato Connessione
            HStack {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text("Stato:")
                    .fontWeight(.semibold)
                    .font(.footnote)
                Text(model.statusMessage)
                    .foregroundColor(.secondary)
                    .font(.footnote)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 4)

            Spacer()

            // Action Buttons
            HStack(spacing: 16) {
                if !model.isRunning {
                    Button(action: {
                        model.startHost()
                    }) {
                        Label("Avvia Host Desktop Remoto", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else {
                    Button(action: {
                        model.stopHost()
                    }) {
                        Label("Ferma Host e Disconnetti", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .padding(22)
        .onAppear {
            model.checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkPermissions()
        }
    }
}
