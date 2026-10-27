import Foundation
import CoreMedia
import CoreVideo
import WebRTC

/// Custom capturer per iniettare i frame CVPixelBuffer di ScreenCaptureKit nella pipeline WebRTC
public final class ScreenVideoCapturer: RTCVideoCapturer {
    public func sendPixelBuffer(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timeStampNs: Int64
        if CMTIME_IS_VALID(timestamp) && CMTimeGetSeconds(timestamp).isFinite && CMTimeGetSeconds(timestamp) > 0 {
            timeStampNs = Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
        } else {
            timeStampNs = Int64(mach_absolute_time())
        }
        let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: timeStampNs)
        self.delegate?.capturer(self, didCapture: frame)
    }
}

public protocol WebRTCManagerDelegate: AnyObject {
    func webRTCStatusDidChange(_ status: String)
    func webRTCClientConnected()
    func webRTCClientDisconnected()
}

/// Gestore principale della connessione Peer-to-Peer WebRTC, DataChannel e streaming video/audio
public final class WebRTCManager: NSObject {
    public weak var delegate: WebRTCManagerDelegate?

    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource!
    private var screenCapturer: ScreenVideoCapturer!
    private var videoTrack: RTCVideoTrack!
    private var audioTrack: RTCAudioTrack!
    private var dataChannel: RTCDataChannel?

    private let signalingClient = SignalingClient()
    private var pollTimer: Timer?
    private var isAnswerSet = false
    private var processedCandidateCount = 0

    private var currentServerBaseUrl: URL?
    private var currentMacId: String?
    private var isOfferRegistered = false
    private var isResettingSession = false
    private var iceGatheringTimeoutItem: DispatchWorkItem?
    private var pendingLocalCandidates: [[String: Any]] = []

    public override init() {
        super.init()
        setupWebRTC()
    }

    private func setupWebRTC() {
        RTCInitializeSSL()

        // Inizializza l'encoder factory usando VideoToolbox per l'accelerazione hardware H.264
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()

        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )

        self.videoSource = factory.videoSource()
        self.screenCapturer = ScreenVideoCapturer(delegate: videoSource)
        self.videoTrack = factory.videoTrack(with: videoSource, trackId: "desktop_video")

        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        self.audioTrack = factory.audioTrack(with: audioSource, trackId: "desktop_audio")
    }

    /// Inoltra il frame acquisito da ScreenCaptureKit a WebRTC
    public func sendVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        screenCapturer.sendPixelBuffer(pixelBuffer, timestamp: timestamp)
    }

    /// Carica le credenziali ICE/TURN da file esterno `ice_servers.json` (escluso da git)
    private func loadIceServers() -> [RTCIceServer] {
        let potentialPaths: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("ice_servers.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("macos-host/ice_servers.json"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ice_servers.json"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ice_servers.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/desktop_remoting/ice_servers.json")
        ]

        for path in potentialPaths {
            if FileManager.default.fileExists(atPath: path.path),
               let data = try? Data(contentsOf: path),
               let servers = parseIceServersJson(data), !servers.isEmpty {
                print("[WebRTC Host] Credenziali ICE caricate con successo da: \(path.path)")
                return servers
            }
        }

        print("[WebRTC Host] Nessun file ice_servers.json trovato, utilizzo configurazione standard di fallback.")
        return [
            RTCIceServer(urlStrings: [
                "stun:stun.l.google.com:19302",
                "stun:stun1.l.google.com:19302",
                "stun:stun2.l.google.com:19302",
                "stun:stun.cloudflare.com:3478"
            ]),
            RTCIceServer(
                urlStrings: [
                    "turn:openrelay.metered.ca:80",
                    "turn:openrelay.metered.ca:443",
                    "turn:openrelay.metered.ca:443?transport=tcp"
                ],
                username: "openrelayproject",
                credential: "openrelayproject"
            )
        ]
    }

    private func parseIceServersJson(_ data: Data) -> [RTCIceServer]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var result: [RTCIceServer] = []
        for obj in array {
            var urlStrings: [String] = []
            if let urlsArr = obj["urls"] as? [String] {
                urlStrings = urlsArr
            } else if let singleUrl = obj["urls"] as? String {
                urlStrings = [singleUrl]
            }
            guard !urlStrings.isEmpty else { continue }
            let username = obj["username"] as? String
            let credential = obj["credential"] as? String ?? obj["password"] as? String
            if let u = username, let c = credential, !u.isEmpty, !c.isEmpty {
                result.append(RTCIceServer(urlStrings: urlStrings, username: u, credential: c))
            } else {
                result.append(RTCIceServer(urlStrings: urlStrings))
            }
        }
        return result
    }

    /// Avvia la creazione dell'offerta WebRTC e la registra sul backend PHP
    public func startHostSession(serverBaseUrl: URL, macId: String) {
        self.currentServerBaseUrl = serverBaseUrl
        self.currentMacId = macId
        self.videoTrack.isEnabled = true
        self.isResettingSession = false
        self.createOfferAndStartSession(serverBaseUrl: serverBaseUrl, macId: macId)
    }

    /// Crea l'istanza di RTCPeerConnection e registra l'SDP Offer (usato sia al primo avvio che dopo disconnessione)
    private func createOfferAndStartSession(serverBaseUrl: URL, macId: String) {
        let config = RTCConfiguration()
        config.iceServers = loadIceServers()
        config.iceTransportPolicy = .all
        config.sdpSemantics = .unifiedPlan
        // In modalità Vanilla ICE raccogliamo i candidati una volta sola fino allo stato complete
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "false",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            delegate?.webRTCStatusDidChange("Errore creazione PeerConnection")
            return
        }
        self.peerConnection = pc

        // Aggiungi le tracce Video e Audio esistenti
        pc.add(videoTrack, streamIds: ["mac_stream"])
        pc.add(audioTrack, streamIds: ["mac_stream"])

        // Configura il DataChannel per la ricezione ultra-veloce degli input mouse/tastiera
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = false      // Bassa latenza: pacchetti di movimento mouse non bloccati da riordino
        dcConfig.maxRetransmits = 0     // Nessuna ritrasmissione per input continui
        if let dc = pc.dataChannel(forLabel: "input", configuration: dcConfig) {
            self.dataChannel = dc
            dc.delegate = self
        }

        delegate?.webRTCStatusDidChange("Generazione SDP Offer...")
        self.isOfferRegistered = false
        self.isAnswerSet = false
        self.pendingLocalCandidates.removeAll()

        // Crea offerta SDP locale
        pc.offer(for: constraints) { [weak self] offerSdp, error in
            guard let self = self, let offerSdp = offerSdp, error == nil else {
                self?.delegate?.webRTCStatusDidChange("Errore generazione Offer: \(String(describing: error))")
                return
            }

            pc.setLocalDescription(offerSdp) { [weak self] setLocalError in
                guard let self = self, setLocalError == nil else {
                    self?.delegate?.webRTCStatusDidChange("Errore impostazione Local Description: \(String(describing: setLocalError))")
                    return
                }

                self.delegate?.webRTCStatusDidChange("Raccolta candidati ICE (Vanilla ICE)...")

                // Timeout di sicurezza di 3 secondi nel caso i server STUN/TURN tardino a rispondere
                let timerItem = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.isOfferRegistered else { return }
                    print("[WebRTC Host] Timeout raccolta ICE (3s) raggiunto: invio Offer con candidati disponibili.")
                    self.sendOfferWithGatheredCandidates(serverBaseUrl: serverBaseUrl, macId: macId)
                }
                self.iceGatheringTimeoutItem = timerItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timerItem)

                // Se per caso la raccolta è già completata
                if pc.iceGatheringState == .complete {
                    self.sendOfferWithGatheredCandidates(serverBaseUrl: serverBaseUrl, macId: macId)
                }
            }
        }
    }

    /// Esegue il reset automatico della sessione e genera una nuova Offer per il prossimo client
    public func triggerSessionReset(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.currentServerBaseUrl != nil, self.currentMacId != nil else { return }
            guard !self.isResettingSession else { return }
            self.isResettingSession = true

            print("[WebRTC Host] Reset sessione avviato (Motivo: \(reason)). Rigenerazione offerta per nuovo client...")
            self.delegate?.webRTCStatusDidChange("Client disconnesso (\(reason)). Rigenerazione offerta per nuovo client...")
            self.delegate?.webRTCClientDisconnected()

            // Ferma polling e timer
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.iceGatheringTimeoutItem?.cancel()
            self.iceGatheringTimeoutItem = nil

            // Rilascia PeerConnection e DataChannel precedenti (mantenendo ScreenCaptureKit e videoTrack intatti)
            self.dataChannel?.close()
            self.dataChannel = nil
            self.peerConnection?.close()
            self.peerConnection = nil
            self.isOfferRegistered = false
            self.isAnswerSet = false
            self.processedCandidateCount = 0

            // Attendi 400ms per garantire il rilascio delle risorse prima di ricreare
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, let url = self.currentServerBaseUrl, let id = self.currentMacId else {
                    self?.isResettingSession = false
                    return
                }
                self.isResettingSession = false
                print("[WebRTC Host] Creazione nuova PeerConnection per il prossimo client...")
                self.createOfferAndStartSession(serverBaseUrl: url, macId: id)
            }
        }
    }

    /// Invia l'SDP Offer completo con tutti i candidati ICE incorporati al server PHP
    private func sendOfferWithGatheredCandidates(serverBaseUrl: URL, macId: String) {
        guard !isOfferRegistered else { return }
        isOfferRegistered = true
        iceGatheringTimeoutItem?.cancel()
        iceGatheringTimeoutItem = nil

        guard let localSdp = peerConnection?.localDescription?.sdp else {
            delegate?.webRTCStatusDidChange("Errore: localDescription SDP non disponibile")
            return
        }

        print("[WebRTC Host] Invio Offer completo (Vanilla ICE) al server PHP (\(localSdp.count) caratteri)...")
        Task {
            do {
                self.delegate?.webRTCStatusDidChange("Registrazione Offer (Vanilla ICE) sul server PHP...")
                try await self.signalingClient.registerOffer(
                    serverBaseUrl: serverBaseUrl,
                    macId: macId,
                    sdp: localSdp
                )
                self.delegate?.webRTCStatusDidChange("In attesa del Client Mobile...")
                self.startPollingForAnswer(serverBaseUrl: serverBaseUrl, macId: macId)
            } catch {
                self.delegate?.webRTCStatusDidChange("Errore registrazione offerta: \(error.localizedDescription)")
            }
        }
    }

    /// Avvia il polling continuo per attendere l'Answer SDP e i candidati ICE dal Client Mobile
    private func startPollingForAnswer(serverBaseUrl: URL, macId: String) {
        self.isAnswerSet = false
        self.processedCandidateCount = 0

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task {
                    do {
                        let response = try await self.signalingClient.pollAnswer(
                            serverBaseUrl: serverBaseUrl,
                            macId: macId,
                            sinceIndex: self.processedCandidateCount
                        )

                        // 0. Se il client richiede un reset della sessione dal file CSV
                        if let resetReq = response.reset_requested, resetReq, self.isAnswerSet {
                            print("[WebRTC Host] Richiesta di reset rilevata dal server PHP.")
                            self.triggerSessionReset(reason: "Richiesta reset dal client")
                            return
                        }

                        // 1. Se riceviamo la risposta SDP dal client e non è ancora stata impostata
                        if let hasAnswer = response.has_answer, hasAnswer,
                           let answerSdp = response.sdp_answer, !self.isAnswerSet {
                            self.isAnswerSet = true
                            let sdpDesc = RTCSessionDescription(type: .answer, sdp: answerSdp)
                            do {
                                try await self.peerConnection?.setRemoteDescription(sdpDesc)
                                self.delegate?.webRTCStatusDidChange("Risposta Client ricevuta! Negoziazione completata.")
                            } catch {
                                print("[WebRTC] Errore impostazione Remote Description: \(error)")
                            }
                        }

                        // 2. Aggiungi i nuovi candidati ICE inviati dal client
                        if let candidates = response.candidates, !candidates.isEmpty {
                            for candDict in candidates {
                                if let sdp = candDict["candidate"]?.value as? String {
                                    let sdpMid = candDict["sdpMid"]?.value as? String
                                    var mLineIndex: Int32 = 0
                                    if let val = candDict["sdpMLineIndex"]?.value {
                                        if let i32 = val as? Int32 {
                                            mLineIndex = i32
                                        } else if let i = val as? Int {
                                            mLineIndex = Int32(i)
                                        } else if let num = val as? NSNumber {
                                            mLineIndex = num.int32Value
                                        }
                                    }
                                    let iceCand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLineIndex, sdpMid: sdpMid)
                                    do {
                                        try await self.peerConnection?.add(iceCand)
                                        print("[WebRTC Host] Candidato ICE client aggiunto con successo: \(sdp.prefix(40))...")
                                    } catch {
                                        print("[WebRTC Host] Errore aggiunta candidato ICE: \(error)")
                                    }
                                }
                            }
                            self.processedCandidateCount += candidates.count
                        }
                    } catch {
                        print("[WebRTC Polling] Errore: \(error)")
                    }
                }
            }
        }
    }

    public func stopSession(serverBaseUrl: URL? = nil, macId: String? = nil) {
        isResettingSession = true

        iceGatheringTimeoutItem?.cancel()
        iceGatheringTimeoutItem = nil
        isOfferRegistered = false

        pollTimer?.invalidate()
        pollTimer = nil

        dataChannel?.close()
        dataChannel = nil

        peerConnection?.close()
        peerConnection = nil

        let baseUrl = serverBaseUrl ?? currentServerBaseUrl
        let id = macId ?? currentMacId

        currentServerBaseUrl = nil
        currentMacId = nil
        isAnswerSet = false

        if let bUrl = baseUrl, let mId = id {
            Task {
                await signalingClient.closeSession(serverBaseUrl: bUrl, macId: mId)
            }
        }
        delegate?.webRTCStatusDidChange("Sessione terminata.")
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTC Host Signaling] Stato: \(stateChanged.rawValue)")
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .new:
                print("[WebRTC Host ICE Connection] Stato: new")
            case .checking:
                print("[WebRTC Host ICE Connection] Stato: checking (verifica connettività candidati STUN/TURN in corso)...")
                self.delegate?.webRTCStatusDidChange("Verifica connettività ICE (checking)...")
            case .connected:
                print("[WebRTC Host ICE Connection] Stato: connected (connessione P2P stabilita con successo)!")
                self.delegate?.webRTCStatusDidChange("Connesso al Client Mobile! (P2P Attivo)")
                self.delegate?.webRTCClientConnected()
            case .completed:
                print("[WebRTC Host ICE Connection] Stato: completed (tutti i candidati verificati)")
            case .failed:
                print("[WebRTC Host ICE Connection] Stato: failed (connessione ICE fallita, candidati esauriti)")
                self.delegate?.webRTCStatusDidChange("Connessione P2P fallita. Riavvio sessione per nuova connessione...")
                self.triggerSessionReset(reason: "ICE failed")
            case .disconnected:
                print("[WebRTC Host ICE Connection] Stato: disconnected (connessione interrotta)")
                self.delegate?.webRTCStatusDidChange("Client disconnesso. Riavvio sessione per nuova connessione...")
                self.triggerSessionReset(reason: "ICE disconnected")
            case .closed:
                print("[WebRTC Host ICE Connection] Stato: closed")
                self.triggerSessionReset(reason: "ICE closed")
            case .count:
                break
            @unknown default:
                print("[WebRTC Host ICE Connection] Stato sconosciuto: \(newState.rawValue)")
            }
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        switch newState {
        case .new:
            print("[WebRTC Host Gathering] Stato: new")
        case .gathering:
            print("[WebRTC Host Gathering] Stato: gathering (raccolta candidati ICE in corso)...")
        case .complete:
            print("[WebRTC Host Gathering] Stato: complete (raccolta completata con successo)!")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isOfferRegistered,
                      let baseUrl = self.currentServerBaseUrl,
                      let macId = self.currentMacId else { return }
                self.sendOfferWithGatheredCandidates(serverBaseUrl: baseUrl, macId: macId)
            }
        @unknown default:
            break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("[WebRTC Host Candidate] Candidato generato: \(candidate.sdp.trimmingCharacters(in: .whitespacesAndNewlines))")
        // In modalità Vanilla ICE tutti i candidati vengono impacchettati direttamente nell'SDP Offer al termine della raccolta.
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[RTCDataChannel] Stato cambiato: \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .closed {
            print("[RTCDataChannel] Canale chiuso. Riavvio sessione per nuovo client...")
            self.triggerSessionReset(reason: "DataChannel closed")
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let message = String(data: buffer.data, encoding: .utf8) else {
            return
        }
        if message.contains("\"disconnect\"") {
            print("[WebRTC Host] Ricevuto messaggio esplicito di disconnessione dal client.")
            self.triggerSessionReset(reason: "Disconnessione esplicita client")
            return
        }
        // Inietta immediatamente il comando mouse/tastiera nel sistema operativo
        InputInjector.shared.handleInputJsonString(message)
    }
}
