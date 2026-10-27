import 'dart:convert';
import 'package:http/http.dart' as http;

class PollResult {
  final bool success;
  final bool found;
  final bool hasOffer;
  final String status;
  final bool resetRequested;
  final String? sdpOffer;
  final List<dynamic> candidates;
  final int totalCandidates;
  final List<dynamic>? iceServers;
  final String? error;

  PollResult({
    required this.success,
    required this.found,
    required this.hasOffer,
    this.status = '',
    this.resetRequested = false,
    this.sdpOffer,
    this.candidates = const [],
    this.totalCandidates = 0,
    this.iceServers,
    this.error,
  });

  factory PollResult.fromJson(Map<String, dynamic> json) {
    return PollResult(
      success: json['success'] == true,
      found: json['found'] == true,
      hasOffer: json['has_offer'] == true,
      status: json['status'] as String? ?? '',
      resetRequested: json['reset_requested'] == true,
      sdpOffer: json['sdp_offer'] as String?,
      candidates: json['candidates'] as List<dynamic>? ?? [],
      totalCandidates: json['total_candidates'] as int? ?? 0,
      iceServers: json['ice_servers'] as List<dynamic>?,
      error: json['error'] as String?,
    );
  }
}

/// Servizio di comunicazione HTTP con gli script PHP (register.php e poll.php)
class SignalingService {
  final http.Client _client = http.Client();

  /// Interroga poll.php per recuperare l'offerta SDP e i candidati ICE dell'host macOS
  Future<PollResult> pollHostOffer({
    required String serverBaseUrl,
    required String macId,
    int sinceIndex = 0,
  }) async {
    final cleanUrl = serverBaseUrl.endsWith('/')
        ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
        : serverBaseUrl;

    final uri = Uri.parse('$cleanUrl/poll.php').replace(queryParameters: {
      'mac_id': macId,
      'role': 'client',
      'since_index': sinceIndex.toString(),
    });

    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Errore HTTP ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return PollResult.fromJson(data);
  }

  /// Invia la risposta SDP Answer al server PHP (register.php)
  Future<void> sendAnswer({
    required String serverBaseUrl,
    required String macId,
    required String sdpAnswer,
  }) async {
    final cleanUrl = serverBaseUrl.endsWith('/')
        ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
        : serverBaseUrl;

    final uri = Uri.parse('$cleanUrl/register.php');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'answer',
        'mac_id': macId,
        'role': 'client',
        'sdp': sdpAnswer,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Errore invio SDP Answer: ${response.body}');
    }
  }

  /// Invia un candidato ICE scoperto dal client mobile
  Future<void> sendIceCandidate({
    required String serverBaseUrl,
    required String macId,
    required Map<String, dynamic> candidate,
  }) async {
    final cleanUrl = serverBaseUrl.endsWith('/')
        ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
        : serverBaseUrl;

    final uri = Uri.parse('$cleanUrl/register.php');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'candidate',
        'mac_id': macId,
        'role': 'client',
        'candidate': candidate,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Errore invio ICE Candidate: ${response.body}');
    }
  }

  /// Invia una richiesta di reset sessione all'host tramite il server PHP
  Future<void> sendResetRequest({
    required String serverBaseUrl,
    required String macId,
  }) async {
    final cleanUrl = serverBaseUrl.endsWith('/')
        ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
        : serverBaseUrl;

    final uri = Uri.parse('$cleanUrl/register.php');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'action': 'reset_request',
        'mac_id': macId,
        'role': 'client',
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Errore invio reset request: ${response.body}');
    }
  }

  void dispose() {
    _client.close();
  }
}
