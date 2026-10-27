import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../models/input_event.dart';
import '../services/webrtc_service.dart';

class RemoteDesktopScreen extends StatefulWidget {
  final WebRTCService webrtcService;
  final String macId;

  const RemoteDesktopScreen({
    Key? key,
    required this.webrtcService,
    required this.macId,
  }) : super(key: key);

  @override
  State<RemoteDesktopScreen> createState() => _RemoteDesktopScreenState();
}

class _RemoteDesktopScreenState extends State<RemoteDesktopScreen> {
  final TextEditingController _keyboardInputController = TextEditingController();
  static const double _sensitivity = 1.8;

  // Trackpad state
  DateTime? _lastTapTime;
  DateTime? _downTime;
  Offset? _downPosition;
  bool _hasMoved = false;

  // Two-finger gesture state
  double? _lastTwoFingerY;
  DateTime? _twoFingerDownTime;
  bool _twoFingerMoved = false;

  @override
  void dispose() {
    _keyboardInputController.dispose();
    widget.webrtcService.dispose();
    super.dispose();
  }

  Future<void> _disconnectAndExit() async {
    await widget.webrtcService.sendDisconnect();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _handleTouchpadPanStart(DragStartDetails details) {
    _downPosition = details.localPosition;
    _downTime = DateTime.now();
    _hasMoved = false;
  }

  void _handleTouchpadPanUpdate(DragUpdateDetails details) {
    final dx = details.delta.dx * _sensitivity;
    final dy = details.delta.dy * _sensitivity;

    if (_downPosition != null) {
      final totalDist = (details.localPosition - _downPosition!).distance;
      if (totalDist > 5.0) {
        _hasMoved = true;
      }
    }

    if (_hasMoved) {
      widget.webrtcService.sendInput(MouseMoveRelEvent(dx: dx, dy: dy));
    }
  }

  void _handleTouchpadPanEnd(DragEndDetails details) {
    final now = DateTime.now();
    final elapsed = _downTime != null ? now.difference(_downTime!).inMilliseconds : 999;

    if (!_hasMoved && elapsed < 250) {
      // Tap detection
      if (_lastTapTime != null && now.difference(_lastTapTime!).inMilliseconds < 300) {
        // Double Tap -> Double Click Sinistro
        widget.webrtcService.sendInput(MouseClickEvent(button: 'left', doubleClick: true));
        _lastTapTime = null;
      } else {
        // Single Tap -> Click Sinistro
        _lastTapTime = now;
        widget.webrtcService.sendInput(MouseClickEvent(button: 'left'));
      }
    }
  }

  void _openKeyboardDialog() {
    _keyboardInputController.clear();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.keyboard, color: Colors.blueAccent),
                  const SizedBox(width: 8),
                  const Text('Tastiera Remota',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.backspace_outlined, color: Colors.orangeAccent),
                    tooltip: 'Backspace (Cancella)',
                    onPressed: () {
                      widget.webrtcService.sendInput(KeyEvent(51, isDown: true));
                      widget.webrtcService.sendInput(KeyEvent(51, isDown: false));
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_return, color: Colors.greenAccent),
                    tooltip: 'Invio (Enter)',
                    onPressed: () {
                      widget.webrtcService.sendInput(KeyEvent(36, isDown: true));
                      widget.webrtcService.sendInput(KeyEvent(36, isDown: false));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keyboardInputController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Digita qui per inviare il testo al Mac...',
                  hintStyle: const TextStyle(color: Colors.white30),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onChanged: (text) {
                  if (text.isNotEmpty) {
                    widget.webrtcService.sendInput(TextInputEvent(text));
                    _keyboardInputController.clear();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _disconnectAndExit();
        return false;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF101010),
        body: SafeArea(
          child: Column(
            children: [
              // 1. Header Toolbar
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                color: const Color(0xFF1E1E1E),
                child: Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.arrow_back, color: Color(0xFFFF5252), size: 18),
                      label: const Text(
                        'Disconnetti',
                        style: TextStyle(color: Color(0xFFFF5252), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _disconnectAndExit,
                    ),
                    Expanded(
                      child: Text(
                        'Mac: ${widget.macId}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.keyboard, color: Color(0xFF00E676), size: 18),
                      label: const Text(
                        'Tastiera',
                        style: TextStyle(color: Color(0xFF00E676), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _openKeyboardDialog,
                    ),
                  ],
                ),
              ),

              // 2. Zona Superiore: Player Video (Aspect Fit Contain - No Crop)
              Expanded(
                flex: 11,
                child: Container(
                  color: Colors.black,
                  child: Center(
                    child: RTCVideoView(
                      widget.webrtcService.videoRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    ),
                  ),
                ),
              ),

              // 3. Zona Inferiore: Touchpad Dedicato + Pulsanti Fisici Mouse
              Expanded(
                flex: 9,
                child: Container(
                  color: const Color(0xFF161616),
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    children: [
                      // Area Touchpad Rettangolare Scura
                      Expanded(
                        child: Listener(
                          onPointerDown: (event) {
                            // Rilevamento gesti multitouch
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: _handleTouchpadPanStart,
                            onPanUpdate: _handleTouchpadPanUpdate,
                            onPanEnd: _handleTouchpadPanEnd,
                            child: Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: const Color(0xFF222222),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white12, width: 1),
                              ),
                              child: Stack(
                                children: [
                                  const Center(
                                    child: Text(
                                      'Area Touchpad\nTrascina per muovere • Tocco per click\nDoppio tocco • Tasti fisici sotto',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white30,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                  // Barra laterale per scroll rapido verticale
                                  Positioned(
                                    right: 4,
                                    top: 12,
                                    bottom: 12,
                                    width: 32,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onVerticalDragUpdate: (details) {
                                        widget.webrtcService.sendInput(
                                          MouseScrollEvent(dy: details.delta.dy * 1.5),
                                        );
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.05),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Center(
                                          child: Icon(
                                            Icons.unfold_more,
                                            color: Colors.white38,
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),

                      // Pulsanti Fisici Click Sinistro e Click Destro
                      SizedBox(
                        height: 52,
                        child: Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2C2C2C),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: () {
                                  widget.webrtcService.sendInput(MouseClickEvent(button: 'left'));
                                },
                                child: const Text(
                                  'Click Sinistro',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2C2C2C),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: () {
                                  widget.webrtcService.sendInput(MouseClickEvent(button: 'right'));
                                },
                                child: const Text(
                                  'Click Destro',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
