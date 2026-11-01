import Foundation
import Network
import CoreMedia
import CoreVideo
import VideoToolbox
import AppKit

public struct DiscoveredHost: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.id == rhs.id
    }
}

public protocol LANStreamClientDelegate: AnyObject {
    func clientConnectionStateDidChange(_ state: LANStreamClient.ConnectionState)
    func clientDidReceiveSampleBuffer(_ sampleBuffer: CMSampleBuffer)
}

/// Client di ricezione video e invio input ad altissime prestazioni per rete locale (LAN Direct Mode)
/// Riceve stream H.264 hardware su TCP con TCP_NODELAY e trasmette eventi mouse/tastiera in tempo reale.
public final class LANStreamClient: ObservableObject {
    public static let shared = LANStreamClient()
    public weak var delegate: LANStreamClientDelegate?

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
        case failed(String)

        public var description: String {
            switch self {
            case .disconnected: return "Disconnesso"
            case .connecting(let host): return "Connessione a \(host)..."
            case .connected(let host): return "Connesso a \(host) (Ultra Low Latency)"
            case .failed(let err): return "Errore: \(err)"
            }
        }
    }

    @Published public private(set) var state: ConnectionState = .disconnected
    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []
    @Published public private(set) var currentFPS: Double = 0.0
    @Published public private(set) var currentBitrateMbps: Double = 0.0
    @Published public private(set) var videoResolution: CGSize = .zero

    public private(set) var currentFormatDescription: CMVideoFormatDescription?
    public var onSampleBufferReceived: ((CMSampleBuffer) -> Void)?

    private var videoConnection: NWConnection?
    private var inputConnection: NWConnection?
    private var browser: NWBrowser?

    private var videoReceiveBuffer = Data()
    private let connectionQueue = DispatchQueue(label: "com.desktopremoting.lanclient", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "com.desktopremoting.lanclient.input", qos: .userInteractive)

    // Metriche
    private var frameCount: Int = 0
    private var bytesReceived: Int = 0
    private var lastStatsReset = Date()

    public init() {
        startDiscovery()
    }

    deinit {
        disconnect()
        stopDiscovery()
    }

    // MARK: - Bonjour Discovery (Auto-rilevamento Host su LAN)

    public func startDiscovery() {
        stopDiscovery()
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_desktopremoting._tcp", domain: nil)
        let parameters = NWParameters()
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)

        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            var hosts: [DiscoveredHost] = []
            for result in results {
                let name: String
                switch result.endpoint {
                case .service(let sName, _, _, _):
                    name = sName
                default:
                    name = result.endpoint.debugDescription
                }
                hosts.append(DiscoveredHost(id: name, name: name, endpoint: result.endpoint))
            }
            DispatchQueue.main.async {
                self?.discoveredHosts = hosts
            }
        }

        nwBrowser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[LANStreamClient] Errore Bonjour Browser: \(error)")
            }
        }

        nwBrowser.start(queue: .main)
        self.browser = nwBrowser
    }

    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Connessione Host

    /// Si connette a un host specificando un indirizzo IP o hostname
    public func connect(host: String, videoPort: UInt16 = LANStreamServer.defaultVideoPort, inputPort: UInt16 = LANStreamServer.defaultInputPort) {
        disconnect()

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            self.state = .failed("Indirizzo IP non valido")
            return
        }

        guard let vPort = NWEndpoint.Port(rawValue: videoPort),
              let iPort = NWEndpoint.Port(rawValue: inputPort) else {
            self.state = .failed("Porte non valide")
            return
        }

        let nwHost = NWEndpoint.Host(trimmedHost)
        let videoEndpoint = NWEndpoint.hostPort(host: nwHost, port: vPort)
        let inputEndpoint = NWEndpoint.hostPort(host: nwHost, port: iPort)

        connectToEndpoints(videoEndpoint: videoEndpoint, inputEndpoint: inputEndpoint, displayName: trimmedHost)
    }

    /// Si connette a un endpoint Bonjour rilevato
    public func connect(discoveredHost: DiscoveredHost, videoPort: UInt16 = LANStreamServer.defaultVideoPort, inputPort: UInt16 = LANStreamServer.defaultInputPort) {
        disconnect()

        guard let iPort = NWEndpoint.Port(rawValue: inputPort) else { return }

        // Il videoEndpoint può usare direttamente l'endpoint di servizio Bonjour
        let videoEndpoint = discoveredHost.endpoint

        // Per l'input, estraiamo l'host o ci connettiamo allo stesso host sulla porta input
        let inputEndpoint: NWEndpoint
        switch discoveredHost.endpoint {
        case .service(let name, let type, let domain, let iface):
            inputEndpoint = .service(name: name, type: type, domain: domain, interface: iface)
        case .hostPort(let host, _):
            inputEndpoint = .hostPort(host: host, port: iPort)
        default:
            inputEndpoint = discoveredHost.endpoint
        }

        connectToEndpoints(videoEndpoint: videoEndpoint, inputEndpoint: inputEndpoint, displayName: discoveredHost.name)
    }

    private func connectToEndpoints(videoEndpoint: NWEndpoint, inputEndpoint: NWEndpoint, displayName: String) {
        DispatchQueue.main.async {
            self.state = .connecting(displayName)
            self.delegate?.clientConnectionStateDidChange(self.state)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disabilita Nagle per latenza minima
        tcpOptions.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        // 1. Connessione Video (Porta 52800)
        let vConn = NWConnection(to: videoEndpoint, using: params)
        vConn.stateUpdateHandler = { [weak self, weak vConn] state in
            guard let self = self, let conn = vConn else { return }
            switch state {
            case .ready:
                print("[LANStreamClient] Video Connection PRONTA a \(displayName)")
                DispatchQueue.main.async {
                    self.state = .connected(displayName)
                    self.delegate?.clientConnectionStateDidChange(self.state)
                }
                self.startReceivingVideo(from: conn)
            case .failed(let error):
                print("[LANStreamClient] Errore connessione Video: \(error)")
                DispatchQueue.main.async {
                    self.state = .failed("Errore video: \(error.localizedDescription)")
                    self.delegate?.clientConnectionStateDidChange(self.state)
                }
            case .cancelled:
                print("[LANStreamClient] Video connection annullata")
            default:
                break
            }
        }
        vConn.start(queue: connectionQueue)
        self.videoConnection = vConn

        // 2. Connessione Input (Porta 52801)
        let iConn = NWConnection(to: inputEndpoint, using: params)
        iConn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[LANStreamClient] Input Connection PRONTA a \(displayName)")
            case .failed(let error):
                print("[LANStreamClient] Errore connessione Input: \(error)")
            default:
                break
            }
        }
        iConn.start(queue: inputQueue)
        self.inputConnection = iConn
    }

    public func disconnect() {
        videoConnection?.cancel()
        videoConnection = nil

        inputConnection?.cancel()
        inputConnection = nil

        videoReceiveBuffer.removeAll()
        currentFormatDescription = nil

        DispatchQueue.main.async {
            self.state = .disconnected
            self.delegate?.clientConnectionStateDidChange(self.state)
            self.currentFPS = 0.0
            self.currentBitrateMbps = 0.0
            self.videoResolution = .zero
        }
    }

    // MARK: - Ricezione e Parsing Pacchetti Video (H.264)

    private func startReceivingVideo(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] content, _, isComplete, error in
            guard let self = self, let conn = connection else { return }

            if let data = content, !data.isEmpty {
                self.processIncomingVideoData(data)
            }

            if error == nil && !isComplete {
                self.startReceivingVideo(from: conn)
            } else if let err = error {
                print("[LANStreamClient] Errore lettura video stream: \(err)")
                DispatchQueue.main.async {
                    self.state = .failed("Connessione interrotta: \(err.localizedDescription)")
                    self.delegate?.clientConnectionStateDidChange(self.state)
                }
            }
        }
    }

    private func processIncomingVideoData(_ data: Data) {
        videoReceiveBuffer.append(data)

        // Protocol Header: 13 bytes
        // [0...3]   UInt32 BigEndian: payload length
        // [4]       UInt8: packet type (0x01 = Config SPS/PPS, 0x02 = Video Slice)
        // [5...12]  Int64 BigEndian: presentation timestamp
        while videoReceiveBuffer.count >= 13 {
            let b0 = UInt32(videoReceiveBuffer[0])
            let b1 = UInt32(videoReceiveBuffer[1])
            let b2 = UInt32(videoReceiveBuffer[2])
            let b3 = UInt32(videoReceiveBuffer[3])
            let payloadLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)

            let packetType = videoReceiveBuffer[4]

            var tsRaw: UInt64 = 0
            for i in 0..<8 {
                tsRaw = (tsRaw << 8) | UInt64(videoReceiveBuffer[5 + i])
            }
            let timestamp = Int64(bitPattern: tsRaw)

            let totalPacketLength = 13 + payloadLen
            if videoReceiveBuffer.count < totalPacketLength {
                // Il pacchetto non è ancora arrivato completamente, attendi il prossimo chunk TCP
                break
            }

            let payload = videoReceiveBuffer.subdata(in: 13..<totalPacketLength)
            videoReceiveBuffer.removeSubrange(0..<totalPacketLength)

            handleVideoPacket(type: packetType, timestamp: timestamp, payload: payload)
            updateStats(bytes: totalPacketLength)
        }
    }

    private func handleVideoPacket(type: UInt8, timestamp: Int64, payload: Data) {
        switch type {
        case 0x01:
            // Type 1: Config Packet (SPS + PPS)
            parseConfigPacket(payload: payload)

        case 0x02:
            // Type 2: Video Slice NALUs
            parseSlicePacket(payload: payload, timestamp: timestamp)

        default:
            print("[LANStreamClient] Tipo pacchetto sconosciuto: \(type)")
        }
    }

    private func parseConfigPacket(payload: Data) {
        guard payload.count >= 4 else { return }

        let spsLen = Int((UInt16(payload[0]) << 8) | UInt16(payload[1]))
        guard payload.count >= 2 + spsLen + 2 else { return }
        let sps = payload.subdata(in: 2..<(2 + spsLen))

        let ppsOffset = 2 + spsLen
        let ppsLen = Int((UInt16(payload[ppsOffset]) << 8) | UInt16(payload[ppsOffset + 1]))
        guard payload.count >= ppsOffset + 2 + ppsLen else { return }
        let pps = payload.subdata(in: (ppsOffset + 2)..<(ppsOffset + 2 + ppsLen))

        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsPtr = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                let parameterSets: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let parameterSetSizes: [Int] = [sps.count, pps.count]
                var formatDesc: CMVideoFormatDescription?

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSets,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )

                if status == noErr, let desc = formatDesc {
                    self.currentFormatDescription = desc
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    DispatchQueue.main.async {
                        self.videoResolution = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                    }
                    print("[LANStreamClient] Formato video H.264 aggiornato: \(dims.width)x\(dims.height)")
                } else {
                    print("[LANStreamClient] Errore creazione FormatDescription: \(status)")
                }
            }
        }
    }

    private func parseSlicePacket(payload: Data, timestamp: Int64) {
        guard let formatDesc = currentFormatDescription else {
            // In attesa del primo keyframe contenente SPS/PPS
            return
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let bBuffer = blockBuffer else { return }

        payload.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: timestamp, timescale: 1000),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleSize = payload.count

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sBuffer = sampleBuffer else { return }

        // Imposta il flag fondamentale per la riproduzione immediata a latenza zero
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        // Inoltra il frame al display layer
        onSampleBufferReceived?(sBuffer)
        delegate?.clientDidReceiveSampleBuffer(sBuffer)
    }

    // MARK: - Invio Eventi Input (Mouse & Tastiera)

    /// Invia un comando input su connessione TCP dedicata con TCP_NODELAY (trasmissione istantanea)
    public func sendInputEvent(_ dict: [String: Any]) {
        guard let inputConn = inputConnection, case .connected = state else { return }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              var jsonString = String(data: jsonData, encoding: .utf8) else { return }

        jsonString.append("\n")
        guard let packetData = jsonString.data(using: .utf8) else { return }

        inputConn.send(content: packetData, completion: .idempotent)
    }

    // MARK: - Statistiche Real-Time

    private func updateStats(bytes: Int) {
        frameCount += 1
        bytesReceived += bytes

        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsReset)
        if elapsed >= 1.0 {
            let fps = Double(frameCount) / elapsed
            let mbps = (Double(bytesReceived) * 8.0) / (elapsed * 1_000_000.0)

            frameCount = 0
            bytesReceived = 0
            lastStatsReset = now

            DispatchQueue.main.async {
                self.currentFPS = fps
                self.currentBitrateMbps = mbps
            }
        }
    }
}
