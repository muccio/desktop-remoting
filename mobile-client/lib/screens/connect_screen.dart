import 'package:flutter/material.dart';
import '../services/webrtc_service.dart';
import 'remote_desktop_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({Key? key}) : super(key: key);

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final TextEditingController _urlController = TextEditingController(text: 'http://192.168.1.100:8000');
  final TextEditingController _macIdController = TextEditingController(text: 'mac-remote-host');

  bool _isConnecting = false;
  String _status = 'Inserisci i parametri di connessione';
  WebRTCService? _webrtcService;

  Future<void> _startConnection() async {
    final serverUrl = _urlController.text.trim();
    final macId = _macIdController.text.trim();

    if (serverUrl.isEmpty || macId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Compila sia l\'URL del server che il Mac ID')),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
      _status = 'Avvio connessione in corso...';
    });

    final service = WebRTCService();
    _webrtcService = service;

    try {
      await service.connect(
        serverBaseUrl: serverUrl,
        macId: macId,
        onStatusUpdate: (newStatus) {
          if (mounted) {
            setState(() {
              _status = newStatus;
            });
          }
        },
      );

      if (!mounted) return;

      // Naviga alla schermata di streaming e controllo remoto
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RemoteDesktopScreen(
            webrtcService: service,
            macId: macId,
          ),
        ),
      );

      // Reset stato al ritorno
      setState(() {
        _isConnecting = false;
        _status = 'Disconnesso';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _status = 'Errore: ${e.toString()}';
        });
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Errore di Connessione'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              )
            ],
          ),
        );
      }
      await service.dispose();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _macIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Remote Desktop Client'),
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 450),
            child: Card(
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.desktop_mac_rounded,
                      size: 64,
                      color: Colors.blueAccent,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Connessione al Mac Remoto',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Signaling via PHP CSV & Streaming WebRTC P2P',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _urlController,
                      enabled: !_isConnecting,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'URL Server PHP (Signaling)',
                        labelStyle: const TextStyle(color: Colors.grey),
                        hintText: 'http://tuo-server.it/backend-php',
                        hintStyle: const TextStyle(color: Colors.white24),
                        prefixIcon: const Icon(Icons.cloud_queue, color: Colors.blueAccent),
                        filled: true,
                        fillColor: const Color(0xFF2A2A2A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _macIdController,
                      enabled: !_isConnecting,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Mac ID identificativo',
                        labelStyle: const TextStyle(color: Colors.grey),
                        hintText: 'es. mac-remote-host',
                        hintStyle: const TextStyle(color: Colors.white24),
                        prefixIcon: const Icon(Icons.computer, color: Colors.blueAccent),
                        filled: true,
                        fillColor: const Color(0xFF2A2A2A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          _isConnecting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
                                )
                              : const Icon(Icons.info_outline, size: 18, color: Colors.grey),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _status,
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _isConnecting ? null : _startConnection,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(
                        _isConnecting ? 'Connessione in corso...' : 'Connetti al Desktop Remoto',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
