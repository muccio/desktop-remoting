import SwiftUI
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Network

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] Applicazione in chiusura: rilascio stato sleep...")
        SleepPreventer.shared.restoreAllSynchronous()
        LANStreamServer.shared.stopServer()
        LANStreamClient.shared.disconnect()
    }
}

public enum AppRole: String, CaseIterable, Identifiable {
    case host = "Host (MacBook Pro)"
    case client = "Client (iMac 4K)"

    public var id: String { rawValue }
}

public enum HostStreamingMode: String, CaseIterable, Identifiable {
    case lanDirect = "⚡ Rete Locale LAN (Bassa Latenza)"
    case webRTCInternet = "🌐 Remoto Internet (WebRTC / PHP)"

    public var id: String { rawValue }
}

@main
struct HostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = HostViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 650)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - ViewModel
@MainActor
final class HostViewModel: ObservableObject, ScreenCaptureManagerDelegate, WebRTCManagerDelegate, LANStreamServerDelegate, LANStreamClientDelegate {
    // Ruolo principale applicazione
    @Published var appRole: AppRole = {
        if let saved = UserDefaults.standard.string(forKey: "saved_app_role"),
           let role = AppRole(rawValue: saved) {
            return role
        }
        let hostname = Host.current().localizedName?.lowercased() ?? ""
        if hostname.contains("imac") {
            return .client
        }
        return .host
    }() {
        didSet {
            UserDefaults.standard.set(appRole.rawValue, forKey: "saved_app_role")
        }
    }

    // Configurazione Modalità Host
    @Published var streamingMode: HostStreamingMode = .lanDirect
    @Published var serverUrl: String = "https://mariosalvucci.com/backend-php/"
    @Published var macId: String = Host.current().localizedName ?? "mac-remote-host"
    @Published var targetFps: Int = 60
    @Published var selectedResolution: CaptureResolution = .fhd1080
    @Published var statusMessage: String = "Pronto all'avvio"
    @Published var isRunning: Bool = false

    // Configurazione Modalità Client (iMac 4K)
    @Published var targetHostIP: String = ""
    @ObservedObject var lanClient = LANStreamClient.shared
    @ObservedObject var lanServer = LANStreamServer.shared

    // Permessi macOS (necessari per Host)
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
        LANStreamServer.shared.delegate = self
        LANStreamClient.shared.delegate = self

        checkPermissions()
        startPermissionMonitoring()

        // Se sono stati scoperti host via Bonjour, pre-popola targetHostIP
        if let first = LANStreamClient.shared.discoveredHosts.first {
            self.targetHostIP = first.name
        }
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

    // MARK: - Gestione Host

    func startHost() {
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

        // Attiva la prevenzione della sospensione (Idle + Display + opzionale Lid-Close)
        SleepPreventer.shared.startPrevention(preventLidClose: keepLidCloseAwake)

        if streamingMode == .lanDirect {
            // Modalità LAN Ultra Low Latency
            statusMessage = "Avvio server streaming locale ad alte prestazioni..."
            Task {
                do {
                    try await screenCaptureManager.startCapture(targetFps: targetFps, resolution: selectedResolution)
                    try LANStreamServer.shared.startServer(bitRate: 30_000_000)
                    statusMessage = "Server LAN attivo (Porta \(LANStreamServer.defaultVideoPort)). In ascolto..."
                } catch {
                    statusMessage = "Errore avvio server LAN: \(error.localizedDescription)"
                    isRunning = false
                    SleepPreventer.shared.stopPrevention()
                }
            }
        } else {
            // Modalità WebRTC Internet
            guard let url = URL(string: serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                statusMessage = "URL Server non valido"
                isRunning = false
                return
            }

            statusMessage = "Inizializzazione cattura schermo e WebRTC..."
            Task {
                do {
                    try await screenCaptureManager.startCapture(targetFps: targetFps, resolution: selectedResolution)
                    webRTCManager.startHostSession(serverBaseUrl: url, macId: macId)
                } catch {
                    statusMessage = "Errore avvio WebRTC: \(error.localizedDescription)"
                    isRunning = false
                    SleepPreventer.shared.stopPrevention()
                }
            }
        }
    }

    func stopHost() {
        isRunning = false
        isRestartingHost = false
        statusMessage = "Arresto in corso..."

        // Rilascia le asserzioni di sospensione e ripristina pmset
        SleepPreventer.shared.stopPrevention()

        if LANStreamServer.shared.isRunning {
            LANStreamServer.shared.stopServer()
        }

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
        guard streamingMode == .webRTCInternet else { return } // LAN gestisce le riconnessioni automaticamente senza restart
        guard !isRestartingHost else { return }
        isRestartingHost = true

        statusMessage = "Client disconnesso (\(reason)). Riavvio del server in corso..."

        let url = URL(string: serverUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        webRTCManager.stopSession(serverBaseUrl: url, macId: macId)

        Task {
            await screenCaptureManager.stopCapture()

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

    // MARK: - Gestione Client (iMac 4K)

    func connectClient(to host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Inserisci l'indirizzo IP del MacBook Pro"
            return
        }

        LANStreamClient.shared.connect(host: trimmed)
        RemoteDisplayWindowController.showWindow(client: LANStreamClient.shared)
    }

    func connectClient(to discoveredHost: DiscoveredHost) {
        LANStreamClient.shared.connect(discoveredHost: discoveredHost)
        RemoteDisplayWindowController.showWindow(client: LANStreamClient.shared)
    }

    func disconnectClient() {
        LANStreamClient.shared.disconnect()
        RemoteDisplayWindowController.current?.close()
    }

    // MARK: - ScreenCaptureManagerDelegate
    nonisolated func didCaptureVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        if LANStreamServer.shared.isRunning {
            LANStreamServer.shared.sendVideoFrame(pixelBuffer, timestamp: timestamp)
        } else {
            webRTCManager.sendVideoFrame(pixelBuffer, timestamp: timestamp)
        }
    }

    nonisolated func didCaptureAudioSample(_ sampleBuffer: CMSampleBuffer) {
        // Audio bypassato per priorità massima su video e input
    }

    // MARK: - WebRTCManagerDelegate
    nonisolated func webRTCStatusDidChange(_ status: String) {
        Task { @MainActor in
            self.statusMessage = status
        }
    }

    nonisolated func webRTCClientConnected() {
        Task { @MainActor in
            self.statusMessage = "Client Mobile Connesso (Streaming WebRTC attivo)"
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

    // MARK: - LANStreamServerDelegate
    nonisolated func lanServerStatusDidChange(_ status: String) {
        Task { @MainActor in
            self.statusMessage = status
        }
    }

    nonisolated func lanServerClientCountDidChange(_ count: Int) {
        Task { @MainActor in
            if count > 0 {
                self.statusMessage = "Client iMac Connesso (\(count) attivo) - Streaming 60 FPS Ultra-Reattivo"
            } else {
                self.statusMessage = "Server LAN attivo - In attesa di connessione dal client iMac..."
            }
        }
    }

    // MARK: - LANStreamClientDelegate
    nonisolated func clientConnectionStateDidChange(_ state: LANStreamClient.ConnectionState) {
        Task { @MainActor in
            self.statusMessage = state.description
        }
    }

    nonisolated func clientDidReceiveSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Buffer elaborato direttamente dal display layer in RemoteDisplayView
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @ObservedObject var model: HostViewModel

    var allPermissionsGranted: Bool {
        model.isScreenCaptureGranted && model.isAccessibilityGranted
    }

    var body: some View {
        VStack(spacing: 16) {
            // Selettore Ruolo Principale
            Picker("Ruolo", selection: $model.appRole) {
                Label("Host (MacBook Pro)", systemImage: "display").tag(AppRole.host)
                Label("Client (iMac 4K)", systemImage: "desktopcomputer").tag(AppRole.client)
            }
            .pickerStyle(.segmented)
            .padding(.top, 2)

            Divider()

            if model.appRole == .host {
                hostView
            } else {
                clientView
            }

            Spacer()

            // Barra di Stato Comune
            HStack {
                Circle()
                    .fill((model.isRunning || model.lanClient.state != .disconnected) ? Color.green : Color.gray)
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
        }
        .padding(20)
        .onAppear {
            model.checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkPermissions()
        }
    }

    // MARK: - Vista Host (MacBook Pro)
    var hostView: some View {
        VStack(spacing: 14) {
            // Selettore Modalità Streaming
            HStack {
                Text("Modalità Trasmissione:")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Picker("", selection: $model.streamingMode) {
                    ForEach(HostStreamingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                .disabled(model.isRunning)
            }

            if model.streamingMode == .lanDirect {
                lanHostConfigView
            } else {
                webRTCHostConfigView
            }

            // Permessi di Sistema macOS
            permissionsBox

            // Box Gestione Sospensione e Coperchio Chiuso (Clamshell)
            sleepPreventionBox

            // Action Buttons
            HStack(spacing: 16) {
                if !model.isRunning {
                    Button(action: {
                        model.startHost()
                    }) {
                        Label(model.streamingMode == .lanDirect ? "Avvia Server LAN (Bassa Latenza)" : "Avvia Host WebRTC", systemImage: "play.fill")
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
    }

    // Configurazione LAN Host
    var lanHostConfigView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.horizontal.fill")
                    .foregroundColor(.yellow)
                Text("Streaming Diretto LAN (Nessun server esterno)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                if model.isRunning {
                    Text(String(format: "%.0f FPS • %.1f Mbps", model.lanServer.currentFPS, model.lanServer.currentBitrateMbps))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Frame Rate Target:")
                        .font(.footnote)
                        .fontWeight(.semibold)
                    Picker("", selection: $model.targetFps) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS (Ultra-Smooth)").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Risoluzione Trasmessa:")
                        .font(.footnote)
                        .fontWeight(.semibold)
                    Picker("", selection: $model.selectedResolution) {
                        ForEach(CaptureResolution.allCases) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isRunning)
                }
            }

            // Indirizzi IP locali rilevati per connettere l'iMac
            VStack(alignment: .leading, spacing: 4) {
                Text("Indirizzi IP del MacBook Pro su questa rete:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                if model.lanServer.localIPAddresses.isEmpty {
                    Text("Nessun IP LAN rilevato (collegati al Wi-Fi, Ethernet o cavo Thunderbolt)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.lanServer.localIPAddresses, id: \.self) { addr in
                                Text(addr)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.12))
                                    .cornerRadius(5)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    // Configurazione WebRTC Host
    var webRTCHostConfigView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("URL Server PHP (Signaling):")
                    .font(.footnote)
                    .fontWeight(.semibold)
                TextField("https://tuo-dominio.it/backend-php/", text: $model.serverUrl)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isRunning)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Identificativo Mac (mac_id):")
                        .font(.footnote)
                        .fontWeight(.semibold)
                    TextField("es. mac-studio-01", text: $model.macId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Frame Rate:")
                        .font(.footnote)
                        .fontWeight(.semibold)
                    Picker("", selection: $model.targetFps) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    // Permessi
    var permissionsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Permessi macOS")
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { model.checkPermissions() }) {
                    Label("Ricarica", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            }

            HStack {
                Image(systemName: model.isScreenCaptureGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.isScreenCaptureGranted ? .green : .red)
                Text("Registrazione Schermo (ScreenCaptureKit)")
                    .font(.caption)
                Spacer()
                if !model.isScreenCaptureGranted {
                    Button("Abilita") { model.requestScreenCapture() }
                        .font(.caption)
                }
            }

            HStack {
                Image(systemName: model.isAccessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.isAccessibilityGranted ? .green : .orange)
                Text("Accessibilità (Controllo Mouse e Tastiera)")
                    .font(.caption)
                Spacer()
                if !model.isAccessibilityGranted {
                    Button("Abilita") { model.requestAccessibility() }
                        .font(.caption)
                }
            }

            if !allPermissionsGranted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ℹ️ Dopo aver attivato la spunta in Impostazioni di Sistema, macOS richiede di riavviare l'app per aggiornare i permessi.")
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
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // Sleep Prevention
    var sleepPreventionBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "powersleep")
                    .foregroundColor(.indigo)
                Text("Gestione Sospensione & Coperchio Chiuso")
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                if model.isRunning && model.sleepPreventer.isLidCloseSleepPrevented {
                    Text("Lid-Close Awake: ATTIVO")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(5)
                }
            }

            Toggle("Mantieni attivo a coperchio chiuso (Clamshell Mode)", isOn: Binding(
                get: { model.keepLidCloseAwake },
                set: { model.updateLidCloseAwakeToggle($0) }
            ))
            .font(.footnote)
            .fontWeight(.semibold)

            Text("Permette di chiudere il coperchio del MacBook Pro continuando a lavorare sull'iMac.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Vista Client (iMac 4K)
    var clientView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Client Ricevitore iMac 4K")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Usa questo iMac come schermo 60 FPS, mouse e tastiera per il MacBook Pro.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                Text("Nessun permesso speciale richiesto su questo iMac (funziona direttamente come display e controller).")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.12))
            .cornerRadius(6)

            Divider()

            // Dispositivi Rilevati via Bonjour
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bonjour")
                        .foregroundColor(.blue)
                    Text("Dispositivi Host rilevati su Rete Locale:")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: {
                        model.lanClient.startDiscovery()
                    }) {
                        Label("Cerca", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }

                if model.lanClient.discoveredHosts.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Ricerca automatica MacBook Pro sulla LAN...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.lanClient.discoveredHosts) { host in
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(host.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Button("Connetti Subito") {
                                    model.connectClient(to: host)
                                }
                                .buttonStyle(.borderedProminent)
                                .font(.caption)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)

            // Connessione Manuale via IP
            VStack(alignment: .leading, spacing: 8) {
                Text("Oppure Connetti Manualmente tramite IP:")
                    .font(.subheadline)
                    .fontWeight(.bold)

                HStack(spacing: 10) {
                    TextField("Es. 192.168.1.50 oppure IP Thunderbolt Bridge", text: $model.targetHostIP)
                        .textFieldStyle(.roundedBorder)

                    Button(action: {
                        model.connectClient(to: model.targetHostIP)
                    }) {
                        Label("Connetti e Apri Schermo", systemImage: "arrow.up.right.video.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(model.targetHostIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("💡 Suggerimento: Se colleghi un cavo Thunderbolt tra iMac e MacBook Pro, usa l'IP dell'interfaccia Thunderbolt Bridge per avere latenza <0.5ms e 40 Gbps di banda!")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)

            // Stato Connessione e Controlli
            if case .connected = model.lanClient.state {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connessione Attiva")
                            .fontWeight(.bold)
                        Spacer()
                        Text(String(format: "%.0f FPS • %.1f Mbps", model.lanClient.currentFPS, model.lanClient.currentBitrateMbps))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    }

                    HStack(spacing: 12) {
                        Button("Mostra Finestra Display") {
                            RemoteDisplayWindowController.showWindow(client: model.lanClient)
                        }
                        .buttonStyle(.bordered)

                        Button("Disconnetti") {
                            model.disconnectClient()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }
}
