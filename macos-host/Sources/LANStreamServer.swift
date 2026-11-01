import Foundation
import Network
import CoreMedia
import CoreVideo
import VideoToolbox

public protocol LANStreamServerDelegate: AnyObject {
    func lanServerStatusDidChange(_ status: String)
    func lanServerClientCountDidChange(_ count: Int)
}

/// Server di streaming ad alte prestazioni per rete locale (LAN Direct Mode)
/// Utilizza VideoToolbox (H.264 real-time senza B-frame) + Network.framework TCP con TCP_NODELAY
/// Nessun server esterno, zero dipendenze cloud, latenza sub-10ms.
public final class LANStreamServer: ObservableObject {
    public static let shared = LANStreamServer()
    public weak var delegate: LANStreamServerDelegate?

    public static let defaultVideoPort: UInt16 = 52800
    public static let defaultInputPort: UInt16 = 52801

    private var videoListener: NWListener?
    private var inputListener: NWListener?

    private var activeVideoConnections: [NWConnection] = []
    private var activeInputConnections: [NWConnection] = []
    private let connectionLock = NSLock()

    private var encoder: VideoToolboxEncoder?
    private var isEncoderInitialized = false
    private var needsKeyframe = true

    // Metriche e statistiche
    private var frameCount: Int = 0
    private var bytesSent: Int = 0
    private var lastStatsReset = Date()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var connectedClients: Int = 0
    @Published public private(set) var currentFPS: Double = 0.0
    @Published public private(set) var currentBitrateMbps: Double = 0.0
    @Published public private(set) var localIPAddresses: [String] = []

    private init() {
        refreshLocalIPs()
    }

    public func refreshLocalIPs() {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) &&
               (flags & IFF_LOOPBACK) == 0 &&
               addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                let name = String(cString: ptr.pointee.ifa_name)
                addresses.append("\(name): \(ip)")
            }
        }
        DispatchQueue.main.async {
            self.localIPAddresses = addresses
        }
    }

    /// Avvia il server di streaming LAN su porta video (52800) e porta input (52801)
    public func startServer(videoPort: UInt16 = defaultVideoPort, inputPort: UInt16 = defaultInputPort, bitRate: Int32 = 25_000_000) throws {
        stopServer()
        refreshLocalIPs()

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disabilita algoritmo di Nagle per trasmissione immediata
        tcpOptions.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true

        // 1. Listener Video (Porta 52800) con annuncio Bonjour
        guard let vPort = NWEndpoint.Port(rawValue: videoPort),
              let iPort = NWEndpoint.Port(rawValue: inputPort) else {
            throw NSError(domain: "LANStreamServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Porta non valida"])
        }

        let vListener = try NWListener(using: params, on: vPort)
        let hostName = Host.current().localizedName ?? "MacHost"
        vListener.service = NWListener.Service(name: hostName, type: "_desktopremoting._tcp")

        vListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewVideoConnection(connection)
        }

        vListener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("[LANStreamServer] Video Listener PRONTO su porta \(videoPort) (Bonjour: _desktopremoting._tcp)")
                    self?.delegate?.lanServerStatusDidChange("Server LAN attivo (Porta \(videoPort))")
                case .failed(let error):
                    print("[LANStreamServer] Errore Video Listener: \(error)")
                    self?.delegate?.lanServerStatusDidChange("Errore LAN: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        vListener.start(queue: .global(qos: .userInteractive))
        self.videoListener = vListener

        // 2. Listener Input (Porta 52801)
        let iListener = try NWListener(using: params, on: iPort)
        iListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewInputConnection(connection)
        }
        iListener.stateUpdateHandler = { state in
            if case .ready = state {
                print("[LANStreamServer] Input Listener PRONTO su porta \(inputPort)")
            }
        }
        iListener.start(queue: .global(qos: .userInteractive))
        self.inputListener = iListener

        self.isRunning = true
        self.needsKeyframe = true
    }

    public func stopServer() {
        isRunning = false
        connectionLock.lock()
        for conn in activeVideoConnections {
            conn.cancel()
        }
        activeVideoConnections.removeAll()

        for conn in activeInputConnections {
            conn.cancel()
        }
        activeInputConnections.removeAll()
        connectionLock.unlock()

        videoListener?.cancel()
        videoListener = nil

        inputListener?.cancel()
        inputListener = nil

        encoder?.invalidate()
        encoder = nil
        isEncoderInitialized = false

        DispatchQueue.main.async {
            self.connectedClients = 0
            self.currentFPS = 0.0
            self.currentBitrateMbps = 0.0
        }
    }

    // MARK: - Gestione Connessioni

    private func handleNewVideoConnection(_ connection: NWConnection) {
        print("[LANStreamServer] Nuovo client video connesso: \(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.connectionLock.lock()
                self.activeVideoConnections.append(conn)
                let count = self.activeVideoConnections.count
                self.connectionLock.unlock()

                self.needsKeyframe = true // Richiedi subito IDR keyframe per il nuovo client!
                DispatchQueue.main.async {
                    self.connectedClients = count
                    self.delegate?.lanServerClientCountDidChange(count)
                }
            case .cancelled, .failed:
                self.connectionLock.lock()
                self.activeVideoConnections.removeAll { $0 === conn }
                let count = self.activeVideoConnections.count
                self.connectionLock.unlock()
                DispatchQueue.main.async {
                    self.connectedClients = count
                    self.delegate?.lanServerClientCountDidChange(count)
                }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInteractive))
    }

    private func handleNewInputConnection(_ connection: NWConnection) {
        print("[LANStreamServer] Nuovo client input connesso: \(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.connectionLock.lock()
                self.activeInputConnections.append(conn)
                self.connectionLock.unlock()
                self.readInputPackets(from: conn)
            case .cancelled, .failed:
                self.connectionLock.lock()
                self.activeInputConnections.removeAll { $0 === conn }
                self.connectionLock.unlock()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInteractive))
    }

    private func readInputPackets(from connection: NWConnection) {
        // Legge messaggi delimitati da newline (\n)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] content, _, isComplete, error in
            guard let self = self, let conn = connection else { return }
            if let data = content, !data.isEmpty,
               let text = String(data: data, encoding: .utf8) {
                // Possono arrivare più comandi separati da \n
                let lines = text.split(separator: "\n")
                for line in lines {
                    let cmd = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cmd.isEmpty {
                        InputInjector.shared.handleInputJsonString(cmd)
                    }
                }
            }

            if error == nil && !isComplete {
                self.readInputPackets(from: conn)
            }
        }
    }

    // MARK: - Pipeline Video (ScreenCaptureKit -> VideoToolbox -> LAN TCP)

    /// Inoltra il frame acquisito da ScreenCaptureKit all'encoder hardware VideoToolbox
    public func sendVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime, targetResolution: CaptureResolution = .fhd1080, targetFps: Int = 60, bitRate: Int32 = 25_000_000) {
        guard isRunning else { return }

        // Inizializza l'encoder se necessario
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

        if encoder == nil || encoder?.width != width || encoder?.height != height {
            encoder?.invalidate()
            encoder = VideoToolboxEncoder(width: width, height: height, bitRate: bitRate, maxFps: Int32(targetFps)) { [weak self] sampleBuffer in
                self?.handleEncodedSampleBuffer(sampleBuffer)
            }
            needsKeyframe = true
        }

        let forceKey = needsKeyframe
        if forceKey {
            needsKeyframe = false
        }

        encoder?.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: timestamp, forceKeyframe: forceKey)
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let payload = H264FramePayload.from(sampleBuffer: sampleBuffer) else { return }

        // Se è un Keyframe e sono presenti SPS/PPS, invia prima il pacchetto di configurazione (Type 1)
        if payload.isKeyframe, let sps = payload.sps, let pps = payload.pps {
            let configPacket = buildConfigPacket(sps: sps, pps: pps, timestamp: payload.timestampValue)
            broadcastVideoPacket(configPacket)
        }

        // Invia il pacchetto video slice NALUs (Type 2)
        let slicePacket = buildSlicePacket(naluData: payload.naluData, timestamp: payload.timestampValue)
        broadcastVideoPacket(slicePacket)

        // Aggiorna statistiche
        updateStats(bytes: slicePacket.count)
    }

    private func buildConfigPacket(sps: Data, pps: Data, timestamp: Int64) -> Data {
        var spsLen = UInt16(sps.count).bigEndian
        var ppsLen = UInt16(pps.count).bigEndian
        let bodyLength = 2 + sps.count + 2 + pps.count

        var header = Data()
        var payloadLen = UInt32(bodyLength).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: &payloadLen) { Array($0) })
        header.append(0x01) // Type 1: Config (SPS/PPS)
        var ts = timestamp.bigEndian
        header.append(contentsOf: withUnsafeBytes(of: &ts) { Array($0) })

        var packet = header
        packet.append(contentsOf: withUnsafeBytes(of: &spsLen) { Array($0) })
        packet.append(sps)
        packet.append(contentsOf: withUnsafeBytes(of: &ppsLen) { Array($0) })
        packet.append(pps)
        return packet
    }

    private func buildSlicePacket(naluData: Data, timestamp: Int64) -> Data {
        var header = Data()
        var payloadLen = UInt32(naluData.count).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: &payloadLen) { Array($0) })
        header.append(0x02) // Type 2: Video Slice
        var ts = timestamp.bigEndian
        header.append(contentsOf: withUnsafeBytes(of: &ts) { Array($0) })

        var packet = header
        packet.append(naluData)
        return packet
    }

    private func broadcastVideoPacket(_ packet: Data) {
        connectionLock.lock()
        let connections = activeVideoConnections
        connectionLock.unlock()

        guard !connections.isEmpty else { return }

        for conn in connections {
            conn.send(content: packet, completion: .idempotent)
        }
    }

    private func updateStats(bytes: Int) {
        frameCount += 1
        bytesSent += bytes

        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsReset)
        if elapsed >= 1.0 {
            let fps = Double(frameCount) / elapsed
            let mbps = (Double(bytesSent) * 8.0) / (elapsed * 1_000_000.0)

            frameCount = 0
            bytesSent = 0
            lastStatsReset = now

            DispatchQueue.main.async {
                self.currentFPS = fps
                self.currentBitrateMbps = mbps
            }
        }
    }
}
