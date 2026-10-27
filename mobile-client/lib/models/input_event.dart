import 'dart:convert';

/// Rappresenta un evento di input da inviare all'Host macOS via WebRTC DataChannel
abstract class InputEvent {
  Map<String, dynamic> toJson();

  String serialize() => jsonEncode(toJson());
}

/// Movimento del puntatore con coordinate normalizzate (0.0 a 1.0)
class MouseMoveEvent extends InputEvent {
  final double x;
  final double y;

  MouseMoveEvent(this.x, this.y);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'mouse_move',
        'x': x.clamp(0.0, 1.0),
        'y': y.clamp(0.0, 1.0),
      };
}

/// Click premuto (down)
class MouseDownEvent extends InputEvent {
  final double x;
  final double y;
  final String button; // 'left' o 'right'

  MouseDownEvent(this.x, this.y, {this.button = 'left'});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'mouse_down',
        'x': x.clamp(0.0, 1.0),
        'y': y.clamp(0.0, 1.0),
        'button': button,
      };
}

/// Click rilasciato (up)
class MouseUpEvent extends InputEvent {
  final double x;
  final double y;
  final String button; // 'left' o 'right'

  MouseUpEvent(this.x, this.y, {this.button = 'left'});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'mouse_up',
        'x': x.clamp(0.0, 1.0),
        'y': y.clamp(0.0, 1.0),
        'button': button,
      };
}

/// Movimento relativo del cursore (trackpad)
class MouseMoveRelEvent extends InputEvent {
  final double dx;
  final double dy;

  MouseMoveRelEvent({required this.dx, required this.dy});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'mouse_move_rel',
        'dx': dx,
        'dy': dy,
      };
}

/// Click rapido del mouse (singolo o doppio)
class MouseClickEvent extends InputEvent {
  final String button; // 'left' o 'right'
  final bool doubleClick;

  MouseClickEvent({this.button = 'left', this.doubleClick = false});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'mouse_click',
        'button': button,
        'double': doubleClick,
      };
}

/// Disconnessione esplicita dal client
class DisconnectEvent extends InputEvent {
  @override
  Map<String, dynamic> toJson() => {
        'type': 'disconnect',
      };
}

/// Scorrimento rotellina del mouse (scroll)
class MouseScrollEvent extends InputEvent {
  final double dx;
  final double dy;

  MouseScrollEvent({this.dx = 0.0, this.dy = 0.0});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'mouse_scroll',
        'dx': dx,
        'dy': dy,
      };
}

/// Pressione/rilascio tasto (tramite keyCode macOS)
class KeyEvent extends InputEvent {
  final int keyCode;
  final bool isDown;

  KeyEvent(this.keyCode, {required this.isDown});

  @override
  Map<String, dynamic> toJson() => {
        'type': isDown ? 'key_down' : 'key_up',
        'keyCode': keyCode,
      };
}

/// Inserimento testo generico da tastiera virtuale
class TextInputEvent extends InputEvent {
  final String text;

  TextInputEvent(this.text);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text_input',
        'text': text,
      };
}
