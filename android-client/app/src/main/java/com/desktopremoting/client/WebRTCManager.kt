package com.desktopremoting.client

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.webrtc.*
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

interface WebRTCListener {
    fun onStatusChange(status: String)
    fun onConnected()
    fun onDisconnected()
}

class WebRTCManager(
    private val context: Context,
    private val listener: WebRTCListener
) {
    val rootEglBase: EglBase = EglBase.create()
    private var peerConnectionFactory: PeerConnectionFactory? = null
    private var peerConnection: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var attachedRenderer: SurfaceViewRenderer? = null
    private var onGatheringCompleteCallback: (() -> Unit)? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var gatheringTimeoutRunnable: Runnable? = null

    init {
        val initOptions = PeerConnectionFactory.InitializationOptions.builder(context)
            .setEnableInternalTracer(false)
            .createInitializationOptions()
        PeerConnectionFactory.initialize(initOptions)

        val videoDecoderFactory = DefaultVideoDecoderFactory(rootEglBase.eglBaseContext)
        val videoEncoderFactory = DefaultVideoEncoderFactory(rootEglBase.eglBaseContext, true, true)

        peerConnectionFactory = PeerConnectionFactory.builder()
            .setVideoDecoderFactory(videoDecoderFactory)
            .setVideoEncoderFactory(videoEncoderFactory)
            .createPeerConnectionFactory()
    }

    fun initRenderer(renderer: SurfaceViewRenderer, onFirstFrame: () -> Unit = {}) {
        this.attachedRenderer = renderer
        renderer.init(rootEglBase.eglBaseContext, object : RendererCommon.RendererEvents {
            override fun onFirstFrameRendered() {
                onFirstFrame()
            }
            override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
                Log.d("WebRTC", "Risoluzione video cambiata: ${videoWidth}x$videoHeight rotation=$rotation")
            }
        })
        renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        renderer.setEnableHardwareScaler(true)
        renderer.setMirror(false)
    }

    fun setScalingType(scalingType: RendererCommon.ScalingType) {
        attachedRenderer?.setScalingType(scalingType)
    }

    fun createPeerConnection(
        videoSink: VideoSink,
        customIceServers: List<PeerConnection.IceServer>? = null,
        onLocalIceCandidate: (IceCandidate) -> Unit
    ) {
        val defaultIceServers = listOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun1.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun2.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun.cloudflare.com:3478").createIceServer(),
            // TURN Relay per attraversamento NAT cellulari e Symmetric NAT (OpenRelay: porte 80, 443 UDP e TCP)
            PeerConnection.IceServer.builder(listOf(
                "turn:openrelay.metered.ca:80",
                "turn:openrelay.metered.ca:443",
                "turn:openrelay.metered.ca:443?transport=tcp"
            ))
                .setUsername("openrelayproject")
                .setPassword("openrelayproject")
                .createIceServer()
        )

        val iceServers = if (!customIceServers.isNullOrEmpty()) {
            val hasTurn = customIceServers.any { s -> s.urls.any { u -> u.startsWith("turn:") } }
            if (!hasTurn) customIceServers + defaultIceServers.filter { s -> s.urls.any { u -> u.startsWith("turn:") } }
            else customIceServers
        } else {
            defaultIceServers
        }

        val rtcConfig = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            // In Vanilla ICE raccogliamo i candidati una volta sola fino a complete
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
            iceTransportsType = PeerConnection.IceTransportsType.ALL
        }

        val observer = object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: IceCandidate) {
                Log.d("WebRTC", "[ICE Client Candidate] Candidato generato: ${candidate.sdp.trim()}")
                onLocalIceCandidate(candidate)
            }

            override fun onDataChannel(dc: DataChannel) {
                dataChannel = dc
                listener.onStatusChange("Canale dati connesso")
            }

            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                Log.d("WebRTC", "[ICE Client Connection] Stato: $newState")
                when (newState) {
                    PeerConnection.IceConnectionState.NEW -> {
                        Log.d("WebRTC", "[ICE Client Connection] Stato: NEW")
                    }
                    PeerConnection.IceConnectionState.CHECKING -> {
                        Log.d("WebRTC", "[ICE Client Connection] Stato: CHECKING (Verifica connettività candidati STUN/TURN...)")
                        listener.onStatusChange("Verifica candidati ICE (checking)...")
                    }
                    PeerConnection.IceConnectionState.CONNECTED -> {
                        Log.d("WebRTC", "[ICE Client Connection] Stato: CONNECTED (Connessione P2P stabilita con successo!)")
                        listener.onStatusChange("Connessione P2P stabilita")
                        listener.onConnected()
                    }
                    PeerConnection.IceConnectionState.COMPLETED -> {
                        Log.d("WebRTC", "[ICE Client Connection] Stato: COMPLETED (Tutti i controlli completati)")
                    }
                    PeerConnection.IceConnectionState.DISCONNECTED -> {
                        Log.d("WebRTC", "[ICE Client Connection] Stato: DISCONNECTED (Disconnesso)")
                        listener.onStatusChange("Disconnesso dal Mac")
                        listener.onDisconnected()
                    }
                    PeerConnection.IceConnectionState.FAILED -> {
                        Log.d("WebRTC", "[ICE Client Connection] Stato: FAILED (Connessione fallita - verifica TURN/Firewall)")
                        listener.onStatusChange("Connessione P2P fallita (verifica TURN/Firewall)")
                        listener.onDisconnected()
                    }
                    PeerConnection.IceConnectionState.CLOSED -> {
                        Log.d("WebRTC", "[ICE Client Connection] Stato: CLOSED")
                    }
                }
            }

            override fun onAddTrack(receiver: RtpReceiver, mediaStreams: Array<out MediaStream>) {
                val track = receiver.track()
                if (track is VideoTrack) {
                    track.setEnabled(true)
                    track.addSink(videoSink)
                    listener.onStatusChange("Flusso video ricevuto")
                }
            }

            override fun onTrack(transceiver: RtpTransceiver) {
                val track = transceiver.receiver.track()
                if (track is VideoTrack) {
                    track.setEnabled(true)
                    track.addSink(videoSink)
                    listener.onStatusChange("Flusso video agganciato")
                }
            }

            override fun onSignalingChange(state: PeerConnection.SignalingState) {
                Log.d("WebRTC", "[ICE Client Signaling] Stato: $state")
            }

            override fun onIceConnectionReceivingChange(receiving: Boolean) {}

            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {
                Log.d("WebRTC", "[ICE Client Gathering] Stato: $state")
                if (state == PeerConnection.IceGatheringState.COMPLETE) {
                    onGatheringCompleteCallback?.invoke()
                }
            }

            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
            override fun onRemoveStream(stream: MediaStream) {}
            override fun onRenegotiationNeeded() {}
            override fun onAddStream(stream: MediaStream) {}
        }

        peerConnection = peerConnectionFactory?.createPeerConnection(rtcConfig, observer)
    }

    fun setRemoteOfferAndCreateAnswer(
        offerSdp: String,
        onAnswerCreated: (SessionDescription) -> Unit,
        onError: (String) -> Unit
    ) {
        val remoteDesc = SessionDescription(SessionDescription.Type.OFFER, offerSdp)
        peerConnection?.setRemoteDescription(object : SdpObserver {
            override fun onSetSuccess() {
                val constraints = MediaConstraints().apply {
                    mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "true"))
                    mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
                }
                peerConnection?.createAnswer(object : SdpObserver {
                    override fun onCreateSuccess(answerDesc: SessionDescription) {
                        peerConnection?.setLocalDescription(object : SdpObserver {
                            override fun onSetSuccess() {
                                listener.onStatusChange("Raccolta candidati ICE (Vanilla ICE)...")

                                var isFinished = false
                                val finishGathering: () -> Unit = {
                                    if (!isFinished) {
                                        isFinished = true
                                        gatheringTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                                        gatheringTimeoutRunnable = null
                                        onGatheringCompleteCallback = null

                                        val finalSdp = peerConnection?.localDescription ?: answerDesc
                                        Log.d("WebRTC", "Raccolta ICE completata o timeout (Vanilla ICE). Dimensione Answer: ${finalSdp.description.length} caratteri")
                                        onAnswerCreated(finalSdp)
                                    }
                                }

                                onGatheringCompleteCallback = finishGathering

                                val timeoutRunnable = Runnable {
                                    Log.d("WebRTC", "Timeout raccolta ICE (3s) scaduto: invio Answer con candidati disponibili.")
                                    finishGathering()
                                }
                                gatheringTimeoutRunnable = timeoutRunnable
                                mainHandler.postDelayed(timeoutRunnable, 3000)

                                if (peerConnection?.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE) {
                                    finishGathering()
                                }
                            }
                            override fun onSetFailure(s: String?) {
                                onError("setLocalDescription fallito: $s")
                            }
                            override fun onCreateSuccess(desc: SessionDescription?) {}
                            override fun onCreateFailure(s: String?) {}
                        }, answerDesc)
                    }
                    override fun onCreateFailure(s: String?) {
                        onError("createAnswer fallito: $s")
                    }
                    override fun onSetSuccess() {}
                    override fun onSetFailure(s: String?) {}
                }, constraints)
            }
            override fun onSetFailure(s: String?) {
                onError("setRemoteDescription fallito: $s")
            }
            override fun onCreateSuccess(desc: SessionDescription?) {}
            override fun onCreateFailure(s: String?) {}
        }, remoteDesc)
    }

    fun addRemoteIceCandidate(candidate: IceCandidate) {
        peerConnection?.addIceCandidate(candidate)
    }

    fun sendInputEvent(event: InputEvent) {
        val json = event.toJson()
        val buffer = DataChannel.Buffer(ByteBuffer.wrap(json.toByteArray(StandardCharsets.UTF_8)), false)
        dataChannel?.send(buffer)
    }

    fun close() {
        gatheringTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        gatheringTimeoutRunnable = null
        onGatheringCompleteCallback = null

        dataChannel?.close()
        dataChannel = null
        peerConnection?.close()
        peerConnection = null
        peerConnectionFactory?.dispose()
        peerConnectionFactory = null
        rootEglBase.release()
    }

    companion object {
        fun parseIceServersFromJson(jsonArray: JSONArray?): List<PeerConnection.IceServer> {
            val list = mutableListOf<PeerConnection.IceServer>()
            if (jsonArray == null) return list
            for (i in 0 until jsonArray.length()) {
                val obj = jsonArray.optJSONObject(i) ?: continue
                val urls = mutableListOf<String>()
                val rawUrls = obj.opt("urls")
                if (rawUrls is JSONArray) {
                    for (j in 0 until rawUrls.length()) {
                        urls.add(rawUrls.getString(j))
                    }
                } else if (rawUrls is String) {
                    urls.add(rawUrls)
                }
                if (urls.isNotEmpty()) {
                    val builder = PeerConnection.IceServer.builder(urls)
                    val username = obj.optString("username")
                    val credential = obj.optString("credential")
                    if (username.isNotEmpty()) builder.setUsername(username)
                    if (credential.isNotEmpty()) builder.setPassword(credential)
                    list.add(builder.createIceServer())
                }
            }
            return list
        }
    }
}
