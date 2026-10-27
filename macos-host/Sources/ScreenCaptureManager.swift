import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Protocollo per inoltrare i frame video e audio acquisiti da ScreenCaptureKit
public protocol ScreenCaptureManagerDelegate: AnyObject {
    func didCaptureVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime)
    func didCaptureAudioSample(_ sampleBuffer: CMSampleBuffer)
}

/// Risoluzioni disponibili per la trasmissione
public enum CaptureResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p HD (Rete Cellulare / 4G)"
    case fhd1080 = "1080p FHD (Consigliato)"
    case native = "Nativa Retina"

    public var id: String { rawValue }
}

/// Gestore per la cattura hardware ad alte prestazioni del desktop e dell'audio tramite ScreenCaptureKit
public final class ScreenCaptureManager: NSObject {
    public weak var delegate: ScreenCaptureManagerDelegate?

    private var stream: SCStream?
    private let videoOutputQueue = DispatchQueue(label: "com.desktopremoting.screenoutput", qos: .userInteractive)
    private let audioOutputQueue = DispatchQueue(label: "com.desktopremoting.audiooutput", qos: .userInteractive)
    
    public private(set) var isCapturing = false

    public override init() {
        super.init()
    }

    /// Avvia la cattura dello schermo principale con risoluzione e FPS target
    public func startCapture(targetFps: Int = 60, resolution: CaptureResolution = .fhd1080) async throws {
        guard !isCapturing else { return }

        // Recupera le informazioni sui display disponibili
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first else {
            throw NSError(domain: "ScreenCaptureManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nessun display rilevato"])
        }

        // Crea il filtro per catturare l'intero display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Calcola larghezza e altezza in base alla risoluzione desiderata
        var targetWidth = display.width
        var targetHeight = display.height
        let aspectRatio = Double(display.width) / Double(display.height)

        switch resolution {
        case .hd720:
            targetWidth = 1280
            targetHeight = Int(1280.0 / aspectRatio)
        case .fhd1080:
            targetWidth = 1920
            targetHeight = Int(1920.0 / aspectRatio)
        case .native:
            targetWidth = display.width
            targetHeight = display.height
        }

        // Assicura che le dimensioni siano numeri pari (richiesto dai codec hardware)
        targetWidth = (targetWidth / 2) * 2
        targetHeight = (targetHeight / 2) * 2

        // Configurazione dello stream ad alte prestazioni
        let config = SCStreamConfiguration()
        config.width = targetWidth
        config.height = targetHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12 ottimale per VideoToolbox
        config.showsCursor = true
        config.scalesToFit = true

        // Abilita la cattura dell'audio di sistema (supportato nativamente da macOS 13+)
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)

        // Aggiungi gli output video e audio
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoOutputQueue)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioOutputQueue)

        try await scStream.startCapture()
        self.stream = scStream
        self.isCapturing = true
        print("[ScreenCaptureManager] Cattura avviata: \(targetWidth)x\(targetHeight) @ \(targetFps)fps")
    }

    /// Ferma lo stream di cattura
    public func stopCapture() async {
        guard isCapturing, let stream = stream else { return }
        do {
            try await stream.stopCapture()
            self.stream = nil
            self.isCapturing = false
            print("[ScreenCaptureManager] Cattura fermata con successo.")
        } catch {
            print("[ScreenCaptureManager] Errore arresto cattura: \(error)")
        }
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate
extension ScreenCaptureManager: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            guard let imageBuffer = sampleBuffer.imageBuffer else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            delegate?.didCaptureVideoFrame(imageBuffer, timestamp: timestamp)

        case .audio:
            delegate?.didCaptureAudioSample(sampleBuffer)

        case .microphone:
            break

        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenCaptureManager] Stream interrotto con errore: \(error.localizedDescription)")
        self.isCapturing = false
    }
}
