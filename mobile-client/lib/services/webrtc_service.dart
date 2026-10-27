import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../models/input_event.dart';
import 'signaling_service.dart';

/// Gestore della connessione WebRTC, rendering del video remoto e trasmissione comandi di input
class WebRTCService {
  final SignalingService signalingService = SignalingService();
  final RTCVideoRenderer videoRenderer = RTCVideoRenderer();

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  Timer? _icePollTimer;
  int _receivedCandidatesCount = 0;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  /// Inizializza il renderer video e avvia la connessione P2P
  Future<void> connect({
    required String serverBaseUrl,
    required String macId,
    required Function(String status) onStatusUpdate,
  }) async {
    onStatusUpdate('Inizializzazione rendering video...');
    await videoRenderer.initialize();

    onStatusUpdate('Attesa offerta SDP dal Mac ($macId)...');

    // 1. Polling per recuperare l'offerta SDP dell'host
    String? remoteOfferSdp;
    List<dynamic>? serverIceServers;
    int retries = 0;
    const maxRetries = 30; // 30 tentativi (30 secondi)

    while (remoteOfferSdp == null && retries < maxRetries) {
      try {
        final poll = await signalingService.pollHostOffer(
          serverBaseUrl: serverBaseUrl,
          macId: macId,
        );

        if ((poll.status == 'answered' || poll.status == 'ready' || poll.status == 'reset_requested') && retries == 0) {
          onStatusUpdate('Sessione precedente rilevata (${poll.status}). Invio richiesta riavvio host...');
          try {
            await signalingService.sendResetRequest(
              serverBaseUrl: serverBaseUrl,
              macId: macId,
            );
          } catch (_) {}
          retries++;
          await Future.delayed(const Duration(milliseconds: 1200));
          continue;
        }

        if (poll.status == 'waiting' && poll.found && poll.hasOffer && poll.sdpOffer != null) {
          remoteOfferSdp = poll.sdpOffer;
          serverIceServers = poll.iceServers;
          break;
        }
      } catch (e) {
        // Ignora temporanei errori di rete durante il polling
      }
      retries++;
      await Future.delayed(const Duration(seconds: 1));
    }

    if (remoteOfferSdp == null) {
      throw Exception('Timeout: Nessuna offerta SDP ricevuta dal Mac. Assicurati che l\'host sia avviato.');
    }

    onStatusUpdate('Offerta ricevuta! Creazione PeerConnection...');

    // 2. Configura RTCPeerConnection con server STUN e TURN (ricevuti dal server o fallback)
    final Map<String, dynamic> rtcConfig = {
      'iceServers': (serverIceServers != null && serverIceServers.isNotEmpty)
          ? serverIceServers
          : [
              {
                'urls': [
                  'stun:stun.l.google.com:19302',
                  'stun:stun1.l.google.com:19302',
                  'stun:stun2.l.google.com:19302',
                  'stun:stun.cloudflare.com:3478',
                ],
              },
              {
                'urls': [
                  'turn:openrelay.metered.ca:80',
                  'turn:openrelay.metered.ca:443',
                  'turn:openrelay.metered.ca:443?transport=tcp',
                ],
                'username': 'openrelayproject',
                'credential': 'openrelayproject',
              },
            ],
      'iceTransportPolicy': 'all',
      'sdpSemantics': 'unified-plan',
      // In Vanilla ICE raccogliamo i candidati una volta sola fino allo stato complete
      'continualGatheringPolicy': 'gather_once',
    };

    final Map<String, dynamic> constraints = {
      'mandatory': {
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': true,
      },
      'optional': [],
    };

    _peerConnection = await createPeerConnection(rtcConfig, constraints);

    // Gestione traccia video/audio in arrivo
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video') {
        videoRenderer.srcObject = event.streams[0];
        onStatusUpdate('Flusso video ricevuto! Connessione stabilita.');
      }
    };

    // Ricezione DataChannel creato dall'host macOS
    _peerConnection!.onDataChannel = (RTCDataChannel channel) {
      _dataChannel = channel;
      _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          onStatusUpdate('Canale di controllo input aperto e attivo!');
        }
      };
    };

    // Monitoraggio dei candidati generati localmente
    _peerConnection!.onIceCandidate = (RTCIceCandidate? candidate) {
      if (candidate != null && candidate.candidate != null) {
        print('[WebRTC Client Candidate] Candidato generato: ${candidate.candidate!.trim()}');
      }
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      print('[WebRTC Client ICE Connection] Stato: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateNew:
          print('[WebRTC Client ICE] Stato: NEW');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          print('[WebRTC Client ICE] Stato: CHECKING (verifica connettività candidati STUN/TURN)...');
          onStatusUpdate('Verifica candidati ICE (checking)...');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
          _isConnected = true;
          print('[WebRTC Client ICE] Stato: CONNECTED (connessione P2P stabilita con successo)!');
          onStatusUpdate('Connesso (P2P Attivo)');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          print('[WebRTC Client ICE] Stato: COMPLETED (tutti i candidati verificati)');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _isConnected = false;
          print('[WebRTC Client ICE] Stato: DISCONNECTED (disconnesso)');
          onStatusUpdate('Disconnesso dal Mac');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _isConnected = false;
          print('[WebRTC Client ICE] Stato: FAILED (connessione fallita - verifica TURN/Firewall)');
          onStatusUpdate('Connessione P2P fallita (verifica TURN/Firewall)');
          break;
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _isConnected = false;
          print('[WebRTC Client ICE] Stato: CLOSED');
          break;
      }
    };

    // 3. Imposta l'offerta SDP remota dell'Host
    final remoteDesc = RTCSessionDescription(remoteOfferSdp, 'offer');
    await _peerConnection!.setRemoteDescription(remoteDesc);

    // 4. Genera la risposta SDP Answer
    onStatusUpdate('Generazione SDP Answer (Vanilla ICE)...');
    final answer = await _peerConnection!.createAnswer(constraints);
    await _peerConnection!.setLocalDescription(answer);

    // Attesa completamento raccolta ICE (Vanilla ICE) con timeout di sicurezza di 3 secondi
    onStatusUpdate('Raccolta candidati ICE locali in corso...');
    final completer = Completer<void>();
    Timer? timeoutTimer;

    void finishGathering() {
      if (!completer.isCompleted) {
        timeoutTimer?.cancel();
        completer.complete();
      }
    }

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      print('[WebRTC Client Gathering State] $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        finishGathering();
      }
    };

    timeoutTimer = Timer(const Duration(seconds: 3), () {
      print('[WebRTC] Timeout raccolta ICE (3s) scaduto: invio Answer con i candidati raccolti.');
      finishGathering();
    });

    final currentGatheringState = await _peerConnection!.getIceGatheringState();
    if (currentGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      finishGathering();
    }

    await completer.future;

    // Leggi la localDescription che ora contiene tutti i candidati ICE incorporati
    final finalLocalDesc = await _peerConnection!.getLocalDescription();
    final sdpToSend = finalLocalDesc?.sdp ?? answer.sdp!;
    print('[WebRTC Client] Invio Answer completa (Vanilla ICE, ${sdpToSend.length} caratteri)');

    // 5. Invia l'Answer al backend PHP in un'unica chiamata POST
    onStatusUpdate('Invio risposta Answer al server PHP...');
    await signalingService.sendAnswer(
      serverBaseUrl: serverBaseUrl,
      macId: macId,
      sdpAnswer: sdpToSend,
    );

    // 6. Avvia il polling periodico per recuperare eventuali candidati ICE ritardati dell'host
    _startHostIceCandidatePolling(serverBaseUrl, macId);
  }

  void _startHostIceCandidatePolling(String serverBaseUrl, String macId) {
    _icePollTimer?.cancel();
    _receivedCandidatesCount = 0;

    _icePollTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_peerConnection == null) {
        timer.cancel();
        return;
      }

      try {
        final poll = await signalingService.pollHostOffer(
          serverBaseUrl: serverBaseUrl,
          macId: macId,
          sinceIndex: _receivedCandidatesCount,
        );

        if (poll.candidates.isNotEmpty) {
          for (final rawCand in poll.candidates) {
            if (rawCand is Map<String, dynamic>) {
              final cand = RTCIceCandidate(
                rawCand['candidate'] as String?,
                rawCand['sdpMid'] as String?,
                rawCand['sdpMLineIndex'] as int?,
              );
              await _peerConnection?.addCandidate(cand);
            }
          }
          _receivedCandidatesCount += poll.candidates.length;
        }
      } catch (e) {
        // Ignora errori di polling temporanei
      }
    });
  }

  /// Invia un evento di input (mouse/tastiera) tramite il DataChannel WebRTC
  void sendInput(InputEvent event) {
    if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage(event.serialize()));
    }
  }

  /// Invia la notifica di disconnessione esplicita all'host Mac via DataChannel
  Future<void> sendDisconnect() async {
    try {
      sendInput(DisconnectEvent());
      await Future.delayed(const Duration(milliseconds: 100));
    } catch (_) {}
  }

  /// Rilascia tutte le risorse
  Future<void> dispose() async {
    _icePollTimer?.cancel();
    _icePollTimer = null;
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
    await videoRenderer.dispose();
    signalingService.dispose();
    _isConnected = false;
  }
}
