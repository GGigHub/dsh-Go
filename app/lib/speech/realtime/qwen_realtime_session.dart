// Qwen-Audio / Qwen-Omni Realtime WebSocket: App ↔ DashScope full-duplex audio.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'qwen_realtime_log.dart';
import 'qwen_realtime_settings.dart';

sealed class QwenRealtimeEvent {
  const QwenRealtimeEvent();
}

final class QwenRealtimeReady extends QwenRealtimeEvent {
  const QwenRealtimeReady();
}

final class QwenRealtimeSpeechStarted extends QwenRealtimeEvent {
  const QwenRealtimeSpeechStarted();
}

final class QwenRealtimeSpeechStopped extends QwenRealtimeEvent {
  const QwenRealtimeSpeechStopped();
}

final class QwenRealtimeInputDelta extends QwenRealtimeEvent {
  const QwenRealtimeInputDelta(this.text);
  final String text;
}

final class QwenRealtimeInputFinal extends QwenRealtimeEvent {
  const QwenRealtimeInputFinal(this.text);
  final String text;
}

final class QwenRealtimeOutputDelta extends QwenRealtimeEvent {
  const QwenRealtimeOutputDelta(this.text);
  final String text;
}

final class QwenRealtimeOutputFinal extends QwenRealtimeEvent {
  const QwenRealtimeOutputFinal(this.text);
  final String text;
}

final class QwenRealtimeAudioDelta extends QwenRealtimeEvent {
  const QwenRealtimeAudioDelta(this.pcm, {required this.responseId});
  final Uint8List pcm;
  final String responseId;
}

final class QwenRealtimeResponseStarted extends QwenRealtimeEvent {
  const QwenRealtimeResponseStarted(this.responseId);
  final String responseId;
}

final class QwenRealtimeResponseDone extends QwenRealtimeEvent {
  const QwenRealtimeResponseDone(this.responseId);
  final String responseId;
}

final class QwenRealtimeCleared extends QwenRealtimeEvent {
  const QwenRealtimeCleared();
}

final class QwenRealtimeError extends QwenRealtimeEvent {
  const QwenRealtimeError(this.message);
  final String message;
}

final class QwenRealtimeClosed extends QwenRealtimeEvent {
  const QwenRealtimeClosed();
}

/// One DashScope realtime session. Caller owns mic/playback.
class QwenRealtimeSession {
  QwenRealtimeSession({
    Future<WebSocket> Function(Uri uri, {Map<String, dynamic>? headers})? connect,
  }) : _connect = connect ?? ((uri, {headers}) => WebSocket.connect(uri.toString(), headers: headers));

  final Future<WebSocket> Function(Uri uri, {Map<String, dynamic>? headers}) _connect;
  final _events = StreamController<QwenRealtimeEvent>.broadcast();
  WebSocket? _ws;
  int _event = 0;
  bool _closed = false;
  Map<String, Object?>? _pendingUpdate;
  Completer<void>? _updated;

  Stream<QwenRealtimeEvent> get events => _events.stream;

  bool get isOpen => _ws != null && !_closed;

  Future<void> open(QwenRealtimeSettings settings) async {
    if (_closed) throw StateError('session closed');
    final uri = settings.websocketUri;
    if (uri == null) throw ArgumentError('invalid realtime endpoint');
    final key = settings.key.trim();
    if (key.isEmpty) throw ArgumentError('realtime key required');

    final headers = <String, dynamic>{'Authorization': 'Bearer $key'};
    final workspace = settings.workspaceId;
    if (workspace != null) headers['X-DashScope-WorkSpace'] = workspace;

    realtimeLog(
      'open model=${settings.model} omni=${settings.isOmniRealtime} '
      'voice=${settings.voice} workspace=${workspace ?? '(none)'} '
      'key=${realtimeMaskSecret(key)} uri=$uri',
    );
    try {
      final ws = await _connect(uri, headers: headers);
      if (_closed) {
        await ws.close();
        return;
      }
      _ws = ws;
      realtimeLog('websocket connected');
      final updated = _updated = Completer<void>();
      _pendingUpdate = {
        'type': 'session.update',
        'session': _sessionConfig(settings),
      };
      ws.listen(
        _onMessage,
        onError: (Object e) => _fail('connection error: $e'),
        onDone: _onDone,
      );

      try {
        await updated.future.timeout(const Duration(seconds: 20));
        realtimeLog('session.updated ok');
      } on TimeoutException {
        realtimeLog('session.update timed out waiting for session.updated');
        await close();
        throw TimeoutException('realtime session.update timed out');
      }
    } on Object catch (e) {
      realtimeLog('open failed: $e');
      rethrow;
    }
  }

  /// Official field layout differs by model family — do not mix levels.
  static Map<String, Object?> _sessionConfig(QwenRealtimeSettings settings) {
    final voice = settings.voice.trim().isEmpty
        ? (settings.isOmniRealtime ? 'Tina' : qwenRealtimeDefaultVoice)
        : settings.voice.trim();
    if (settings.isOmniRealtime) {
      // qwen3.8-omni-flash-realtime: modalities + voice + server_vad only.
      return {
        'modalities': ['text', 'audio'],
        'voice': voice,
        'instructions': '你是语音助手。用简短、口语化的中文回答，不要用 Markdown、列表或代码块。',
        'turn_detection': {'type': 'server_vad'},
      };
    }
    // qwen-audio-*-realtime-* and older omni shapes.
    return {
      'modalities': ['text', 'audio'],
      'voice': voice,
      'instructions': '你是语音助手。用简短、口语化的中文回答，不要用 Markdown、列表或代码块。',
      'input_audio_format': 'pcm16',
      'output_audio_format': 'pcm16',
      'input_audio_transcription': {'model': 'qwen3-asr-flash-realtime'},
      'turn_detection': {
        'type': 'server_vad',
        'threshold': 0.2,
        'prefix_padding_ms': 300,
        'silence_duration_ms': 600,
      },
      'audio': {
        'input': {
          'format': {'type': 'pcm', 'sample_rate': 16000},
        },
        'output': {
          'format': {'type': 'pcm', 'sample_rate': 24000},
        },
      },
    };
  }

  void appendPcm(Uint8List pcm) {
    if (pcm.isEmpty || _ws == null || _closed) return;
    _send({'type': 'input_audio_buffer.append', 'audio': base64Encode(pcm)});
  }

  void cancelResponse() => _send({'type': 'response.cancel'});

  void interrupt() {
    cancelResponse();
    _emit(const QwenRealtimeCleared());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final waiting = _updated;
    _updated = null;
    _pendingUpdate = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(StateError('session closed'));
    }
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } on Object {
      // Already gone.
    }
    if (!_events.isClosed) {
      _events.add(const QwenRealtimeClosed());
      await _events.close();
    }
  }

  void _send(Map<String, Object?> event) {
    final ws = _ws;
    if (ws == null || _closed) return;
    event.putIfAbsent('event_id', () => 'event_${++_event}');
    final type = event['type'];
    if (type == 'session.update') {
      final session = event['session'];
      realtimeLog(
        'send session.update keys=${session is Map ? session.keys.toList() : session}',
      );
    } else if (type != 'input_audio_buffer.append') {
      realtimeLog('send $type');
    }
    try {
      ws.add(jsonEncode(event));
    } on Object catch (e) {
      _fail('send failed: $e');
    }
  }

  void _onMessage(dynamic raw) {
    if (_closed) return;
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (decoded is Map<String, dynamic>) {
        json = decoded;
      } else if (decoded is Map) {
        json = decoded.map((k, v) => MapEntry('$k', v));
      }
    } on Object catch (e) {
      realtimeLog('bad server frame: $e');
      return;
    }
    if (json == null) return;
    final type = json['type'];
    if (type is! String) return;
    // Skip high-frequency audio/text deltas in logcat.
    if (type != 'response.audio.delta' &&
        type != 'response.audio_transcript.delta' &&
        type != 'response.text.delta' &&
        type != 'conversation.item.input_audio_transcription.delta') {
      realtimeLog('recv $type');
    }
    switch (type) {
      case 'session.created':
        final pending = _pendingUpdate;
        _pendingUpdate = null;
        if (pending != null) _send(pending);
      case 'session.updated':
        final waiting = _updated;
        _updated = null;
        if (waiting != null && !waiting.isCompleted) waiting.complete();
        _emit(const QwenRealtimeReady());
      case 'input_audio_buffer.speech_started':
        _emit(const QwenRealtimeSpeechStarted());
      case 'input_audio_buffer.speech_stopped':
        _emit(const QwenRealtimeSpeechStopped());
      case 'conversation.item.input_audio_transcription.delta':
        final delta = json['delta'];
        if (delta is String && delta.isNotEmpty) _emit(QwenRealtimeInputDelta(delta));
      case 'conversation.item.input_audio_transcription.completed':
        final text = json['transcript'] ?? json['text'];
        if (text is String) _emit(QwenRealtimeInputFinal(text));
      case 'response.created':
        final id = _responseId(json);
        if (id != null) _emit(QwenRealtimeResponseStarted(id));
      case 'response.audio_transcript.delta' || 'response.text.delta':
        final delta = json['delta'];
        if (delta is String && delta.isNotEmpty) _emit(QwenRealtimeOutputDelta(delta));
      case 'response.audio_transcript.done' || 'response.text.done':
        final text = json['transcript'] ?? json['text'];
        if (text is String) _emit(QwenRealtimeOutputFinal(text));
      case 'response.audio.delta':
        final delta = json['delta'];
        final id = _responseId(json) ?? 'audio';
        if (delta is String && delta.isNotEmpty) {
          try {
            _emit(QwenRealtimeAudioDelta(base64Decode(delta), responseId: id));
          } on Object {
            // Bad chunk: skip.
          }
        }
      case 'response.done' || 'response.audio.done':
        final id = _responseId(json) ?? '';
        _emit(QwenRealtimeResponseDone(id));
      case 'error':
        final err = json['error'];
        final message = err is Map
            ? '${err['code'] ?? ''} ${err['message'] ?? err}'.trim()
            : '$err';
        realtimeLog('server error raw=$err');
        _fail(message.isEmpty ? 'realtime error' : message);
      default:
        break;
    }
  }

  String? _responseId(Map<String, dynamic> json) {
    final direct = json['response_id'];
    if (direct is String && direct.isNotEmpty) return direct;
    final response = json['response'];
    if (response is Map && response['id'] is String) return response['id'] as String;
    final id = json['item_id'];
    if (id is String && id.isNotEmpty) return id;
    return null;
  }

  void _onDone() {
    _ws = null;
    if (!_closed) _fail('connection closed');
  }

  void _fail(String message) {
    if (_closed) return;
    realtimeLog('fail: $message');
    final waiting = _updated;
    if (waiting != null && !waiting.isCompleted) waiting.completeError(StateError(message));
    _emit(QwenRealtimeError(message));
    unawaited(close());
  }

  void _emit(QwenRealtimeEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
