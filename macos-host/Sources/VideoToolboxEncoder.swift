import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Callback per i frame codificati in hardware
public typealias VideoToolboxEncoderOutputHandler = (CMSampleBuffer) -> Void

/// Wrapper per la compressione video hardware a bassissima latenza tramite VideoToolbox
public final class VideoToolboxEncoder {
    private var session: VTCompressionSession?
    private let outputHandler: VideoToolboxEncoderOutputHandler
    
    public let width: Int32
    public let height: Int32
    public let bitRate: Int32
    public let maxFps: Int32

    public init(width: Int32, height: Int32, bitRate: Int32 = 4_000_000, maxFps: Int32 = 60, outputHandler: @escaping VideoToolboxEncoderOutputHandler) {
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.maxFps = maxFps
        self.outputHandler = outputHandler
        setupCompressionSession()
    }

    deinit {
        invalidate()
    }

    /// Configura la sessione di compressione hardware Apple VideoToolbox
    private func setupCompressionSession() {
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else {
                return
            }
            let encoder = Unmanaged<VideoToolboxEncoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.outputHandler(sampleBuffer)
        }

        let refCon = Unmanaged.passUnretained(self).toOpaque()

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refCon,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("[VideoToolboxEncoder] Errore creazione sessione: \(status)")
            return
        }

        // Impostazioni per streaming interattivo a bassissima latenza
        // 1. Modalità Real-Time abilitata
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // 2. Profilo H.264 High AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        // 3. Bitrate target medio
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)

        // 4. Disabilita il riordinamento dei frame (Nessun B-Frame per azzerare la latenza di decodifica)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // 5. Intervallo massimo tra key-frame (es. 1 keyframe al secondo a 60fps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: maxFps as CFNumber)

        // 6. Limite bitrate di picco per evitare congestione
        let byteLimit = (bitRate / 8) * 2
        let secLimit: Double = 1.0
        let dataRateLimits = [byteLimit, secLimit] as NSArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[VideoToolboxEncoder] Sessione VideoToolbox H.264 inizializzata con successo (\(width)x\(height), \(bitRate/1000) kbps)")
    }

    /// Comprime un CVPixelBuffer proveniente da ScreenCaptureKit
    public func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, duration: CMTime = .invalid, forceKeyframe: Bool = false) {
        guard let session = session else { return }

        var flags: VTEncodeInfoFlags = []
        var frameProperties: CFDictionary? = nil
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )

        if status != noErr {
            print("[VideoToolboxEncoder] Errore codifica frame: \(status)")
        }
    }

    public func invalidate() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
}

/// Struttura di supporto per estrarre SPS, PPS e NALU da un CMSampleBuffer compresso
public struct H264FramePayload {
    public let isKeyframe: Bool
    public let sps: Data?
    public let pps: Data?
    public let naluData: Data
    public let timestampValue: Int64
    public let timescale: Int32

    public static func from(sampleBuffer: CMSampleBuffer) -> H264FramePayload? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var lengthAtOffsetOut: Int = 0
        var totalLengthOut: Int = 0
        var dataPointerOut: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffsetOut, totalLengthOut: &totalLengthOut, dataPointerOut: &dataPointerOut) == noErr,
              let ptr = dataPointerOut else { return nil }
        let naluData = Data(bytes: ptr, count: totalLengthOut)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var spsData: Data? = nil
        var ppsData: Data? = nil

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsPtr: UnsafePointer<UInt8>?
            var spsSize: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = spsPtr {
                spsData = Data(bytes: p, count: spsSize)
            }
            var ppsPtr: UnsafePointer<UInt8>?
            var ppsSize: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = ppsPtr {
                ppsData = Data(bytes: p, count: ppsSize)
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return H264FramePayload(
            isKeyframe: isKeyframe,
            sps: spsData,
            pps: ppsData,
            naluData: naluData,
            timestampValue: pts.value,
            timescale: pts.timescale
        )
    }
}
