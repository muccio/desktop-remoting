package com.desktopremoting.client

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.widget.EditText
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.desktopremoting.client.databinding.ActivityRemoteDesktopBinding
import kotlinx.coroutines.*
import org.json.JSONObject
import org.webrtc.IceCandidate
import org.webrtc.RendererCommon
import kotlin.math.abs

class RemoteDesktopActivity : AppCompatActivity(), WebRTCListener {

    private lateinit var binding: ActivityRemoteDesktopBinding
    private var webRTCManager: WebRTCManager? = null
    private val signalingClient = SignalingClient()

    private var serverUrl: String = ""
    private var macId: String = ""
    private val sensitivity = 1.8f

    // Trackpad gesture state
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var downX = 0f
    private var downY = 0f
    private var downTime = 0L
    private var hasMoved = false
    private var lastTapTime = 0L

    // Two-finger gesture state
    private var lastTwoFingerY = 0f
    private var twoFingerDownTime = 0L
    private var twoFingerMoved = false

    private var connectionJob: Job? = null
    private var isDisconnecting = false

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityRemoteDesktopBinding.inflate(layoutInflater)
        setContentView(binding.root)

        serverUrl = intent.getStringExtra("SERVER_URL") ?: ""
        macId = intent.getStringExtra("MAC_ID") ?: ""

        setupUI()
        initWebRTCAndConnect()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupUI() {
        binding.tvHeaderTitle.text = "Mac: $macId"

        binding.btnBack.setOnClickListener {
            disconnectAndExit()
        }

        binding.btnCancelLoading.setOnClickListener {
            disconnectAndExit()
        }

        binding.btnKeyboard.setOnClickListener {
            showKeyboardDialog()
        }

        // Pulsanti fisici Mouse Sinistro e Destro
        binding.btnLeftClick.setOnClickListener {
            webRTCManager?.sendInputEvent(MouseClickEvent(button = "left"))
        }

        binding.btnRightClick.setOnClickListener {
            webRTCManager?.sendInputEvent(MouseClickEvent(button = "right"))
        }

        // Area Touchpad dedicata per movimento relativo, tap e scroll
        binding.touchpadArea.setOnTouchListener { _, event ->
            handleTouchpadEvent(event)
            true
        }
    }

    private fun handleTouchpadEvent(event: MotionEvent) {
        val pointerCount = event.pointerCount

        if (pointerCount == 2) {
            // Gestione 2 dita: scroll verticale e click destro su tocco rapido
            val currentTwoFingerY = (event.getY(0) + event.getY(1)) / 2f
            when (event.actionMasked) {
                MotionEvent.ACTION_POINTER_DOWN -> {
                    lastTwoFingerY = currentTwoFingerY
                    twoFingerDownTime = System.currentTimeMillis()
                    twoFingerMoved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dy = currentTwoFingerY - lastTwoFingerY
                    if (abs(dy) > 3f) {
                        twoFingerMoved = true
                        // Invio scroll verticale negativo per scroll naturale Mac
                        webRTCManager?.sendInputEvent(MouseScrollEvent(dy = dy * 1.5f))
                        lastTwoFingerY = currentTwoFingerY
                    }
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    val duration = System.currentTimeMillis() - twoFingerDownTime
                    if (!twoFingerMoved && duration < 300) {
                        // Tocco rapido con 2 dita = Click Destro
                        webRTCManager?.sendInputEvent(MouseClickEvent(button = "right"))
                    }
                }
            }
            return
        }

        if (pointerCount == 1) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    lastTouchX = event.x
                    lastTouchY = event.y
                    downX = event.x
                    downY = event.y
                    downTime = System.currentTimeMillis()
                    hasMoved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val rawDx = event.x - lastTouchX
                    val rawDy = event.y - lastTouchY

                    if (abs(event.x - downX) > 8f || abs(event.y - downY) > 8f) {
                        hasMoved = true
                    }

                    if (hasMoved) {
                        val dx = rawDx * sensitivity
                        val dy = rawDy * sensitivity
                        webRTCManager?.sendInputEvent(MouseMoveRelEvent(dx = dx, dy = dy))
                    }

                    lastTouchX = event.x
                    lastTouchY = event.y
                }
                MotionEvent.ACTION_UP -> {
                    val duration = System.currentTimeMillis() - downTime
                    if (!hasMoved && duration < 250) {
                        val now = System.currentTimeMillis()
                        if (now - lastTapTime < 300) {
                            // Doppio tap = Doppio Click
                            webRTCManager?.sendInputEvent(MouseClickEvent(button = "left", double = true))
                            lastTapTime = 0L
                        } else {
                            // Singolo tap = Click Sinistro
                            lastTapTime = now
                            webRTCManager?.sendInputEvent(MouseClickEvent(button = "left"))
                        }
                    }
                }
            }
        }
    }

    private fun disconnectAndExit() {
        if (isDisconnecting) return
        isDisconnecting = true

        lifecycleScope.launch {
            try {
                // Notifica esplicita all'host via DataChannel per riavvio immediato
                webRTCManager?.sendInputEvent(DisconnectEvent())
                delay(80)
                // Notifica anche al server PHP per garantire che l'Host esegua il restart
                signalingClient.sendResetRequest(serverUrl, macId)
            } catch (e: Exception) {
                Log.e("RemoteDesktop", "Errore invio disconnessione: ${e.message}")
            }
            finish()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        disconnectAndExit()
    }

    private fun showKeyboardDialog() {
        val input = EditText(this).apply {
            hint = "Digita testo da inviare..."
        }
        AlertDialog.Builder(this)
            .setTitle("Tastiera Mac")
            .setView(input)
            .setPositiveButton("Invia") { _, _ ->
                val text = input.text.toString()
                if (text.isNotEmpty()) {
                    webRTCManager?.sendInputEvent(TextInputEvent(text))
                }
            }
            .setNeutralButton("Invio (Enter)") { _, _ ->
                webRTCManager?.sendInputEvent(KeyEvent(36, isDown = true))
                webRTCManager?.sendInputEvent(KeyEvent(36, isDown = false))
            }
            .setNegativeButton("Annulla", null)
            .show()
    }

    private fun initWebRTCAndConnect() {
        val manager = WebRTCManager(this, this)
        webRTCManager = manager

        manager.initRenderer(binding.surfaceViewRenderer) {
            runOnUiThread {
                binding.loadingOverlay.visibility = View.GONE
            }
        }

        connectionJob = lifecycleScope.launch {
            try {
                binding.tvLoadingStatus.text = "In attesa dell'Host Mac..."
                binding.tvLoadingDetails.text = "Verifica sessione '$macId' su $serverUrl"

                var offerSdp: String? = null
                var iceServersJson: org.json.JSONArray? = null
                var attempts = 0

                while (offerSdp == null && attempts < 35) {
                    if (!isActive) return@launch
                    try {
                        val res = signalingClient.pollOffer(serverUrl, macId)
                        val status = res.optString("status")

                        if (res.optBoolean("found") && res.optBoolean("has_offer")) {
                            if ((status == "answered" || status == "ready" || status == "reset_requested") && attempts == 0) {
                                // Sessione precedente già consumata: richiedi reset e riavvio all'Host Mac
                                binding.tvLoadingDetails.text = "Sessione precedente rilevata ($status). Richiesta nuova offerta all'Host..."
                                signalingClient.sendResetRequest(serverUrl, macId)
                                delay(1200)
                                attempts++
                                continue
                            }

                            if (status == "waiting") {
                                offerSdp = res.optString("sdp_offer")
                                iceServersJson = res.optJSONArray("ice_servers")
                                break
                            } else {
                                binding.tvLoadingDetails.text = "In attesa che l'Host completi il riavvio (stato: $status)..."
                            }
                        }
                    } catch (e: Exception) {
                        if (e is CancellationException) return@launch
                        binding.tvLoadingDetails.text = "Connessione server... ${e.message}"
                    }
                    attempts++
                    binding.tvLoadingDetails.text = "Tentativo $attempts di 35: in attesa dell'host '$macId'..."
                    delay(1000)
                }

                if (offerSdp.isNullOrEmpty()) {
                    binding.loadingProgressBar.visibility = View.GONE
                    binding.tvLoadingStatus.text = "Nessuna offerta trovata"
                    binding.tvLoadingDetails.text = "Il Mac '$macId' non è pronto. Assicurati che l'app MacHost sia aperta e clicca su 'Avvia Host Desktop Remoto'."
                    return@launch
                }

                // Inizializza PeerConnection con configurazione STUN/TURN completa
                val customIceServers = WebRTCManager.parseIceServersFromJson(iceServersJson)
                manager.createPeerConnection(binding.surfaceViewRenderer, customIceServers) { localCandidate ->
                    // Vanilla ICE include i candidati direttamente nell'Answer SDP, ma teniamo logica candidati pronta
                    lifecycleScope.launch candScope@ {
                        try {
                            val candJson = JSONObject().apply {
                                put("candidate", localCandidate.sdp)
                                put("sdpMid", localCandidate.sdpMid)
                                put("sdpMLineIndex", localCandidate.sdpMLineIndex)
                            }
                            signalingClient.sendCandidate(serverUrl, macId, candJson)
                        } catch (e: Exception) {
                            if (e is CancellationException) return@candScope
                        }
                    }
                }

                binding.tvLoadingStatus.text = "Offerta SDP ricevuta!"
                binding.tvLoadingDetails.text = "Negoziazione Vanilla ICE (raccolta candidati STUN/TURN)..."

                // Crea Answer e attende iceGatheringState == COMPLETE (Vanilla ICE) prima dell'invio
                manager.setRemoteOfferAndCreateAnswer(
                    offerSdp = offerSdp,
                    onAnswerCreated = { answerDesc ->
                        lifecycleScope.launch answerScope@ {
                            try {
                                binding.tvLoadingStatus.text = "Invio risposta completa al server..."
                                signalingClient.sendAnswer(serverUrl, macId, answerDesc.description)

                                binding.tvLoadingStatus.text = "Connessione P2P in corso..."
                                binding.tvLoadingDetails.text = "Stabilimento canale WebRTC (attraversamento NAT cellulare via TURN se necessario)..."
                            } catch (e: Exception) {
                                if (e is CancellationException) return@answerScope
                                binding.tvLoadingStatus.text = "Errore invio Answer"
                                binding.tvLoadingDetails.text = e.message
                            }
                        }
                    },
                    onError = { err ->
                        runOnUiThread {
                            binding.loadingProgressBar.visibility = View.GONE
                            binding.tvLoadingStatus.text = "Errore negoziazione SDP"
                            binding.tvLoadingDetails.text = err
                        }
                    }
                )
            } catch (e: Exception) {
                if (e is CancellationException) return@launch
                binding.loadingProgressBar.visibility = View.GONE
                binding.tvLoadingStatus.text = "Errore di connessione"
                binding.tvLoadingDetails.text = e.message ?: "Errore sconosciuto"
            }
        }
    }

    override fun onStatusChange(status: String) {
        runOnUiThread {
            if (binding.loadingOverlay.visibility == View.VISIBLE) {
                binding.tvLoadingDetails.text = status
            } else {
                Toast.makeText(this, status, Toast.LENGTH_SHORT).show()
            }
        }
    }

    override fun onConnected() {
        runOnUiThread {
            binding.loadingOverlay.visibility = View.GONE
        }
    }

    override fun onDisconnected() {
        runOnUiThread {
            Toast.makeText(this, "Disconnesso dall'Host Mac", Toast.LENGTH_LONG).show()
            if (!isFinishing && !isDisconnecting) {
                finish()
            }
        }
    }

    override fun onDestroy() {
        connectionJob?.cancel()
        webRTCManager?.close()
        webRTCManager = null
        super.onDestroy()
    }
}
