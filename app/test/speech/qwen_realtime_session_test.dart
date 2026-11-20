import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/speech/realtime/qwen_realtime_session.dart';
import 'package:dsh_app/speech/realtime/qwen_realtime_settings.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSocket implements WebSocket {
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <String>[];
  int readyState = WebSocket.open;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  void add(dynamic data) {
    if (data is String) sent.add(data);
  }

  @override
  Future close([int? code, String? reason]) async {
    readyState = WebSocket.closed;
    await incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('open waits for session.created then sends audio-model session.update', () async {
    final fake = _FakeSocket();
    final session = QwenRealtimeSession(
      connect: (uri, {headers}) async {
        expect(uri.queryParameters['model'], 'qwen-audio-3.1-realtime-flash');
        expect(headers?['Authorization'], 'Bearer sk-testkey0123456789abcdef');
        expect(headers?.containsKey('X-DashScope-WorkSpace'), isFalse);
        return fake;
      },
    );
    final events = session.events.toList();
    final opening = session.open(
      const QwenRealtimeSettings(key: 'sk-testkey0123456789abcdef', model: 'qwen-audio-3.1-realtime-flash'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(fake.sent, isEmpty);
    fake.incoming.add(jsonEncode({'type': 'session.created'}));
    await Future<void>.delayed(Duration.zero);
    expect(fake.sent, isNotEmpty);
    final update = jsonDecode(fake.sent.first) as Map<String, dynamic>;
    expect(update['type'], 'session.update');
    expect((update['session'] as Map)['input_audio_format'], 'pcm16');
    fake.incoming.add(jsonEncode({'type': 'session.updated'}));
    await opening;
    session.appendPcm(Uint8List.fromList([1, 2, 3, 4]));
    final append = jsonDecode(fake.sent.last) as Map<String, dynamic>;
    expect(append['type'], 'input_audio_buffer.append');
    expect(append['audio'], isA<String>());
    fake.incoming.add(
      jsonEncode({
        'type': 'response.audio.delta',
        'response_id': 'r1',
        'delta': base64Encode([9, 8, 7, 6]),
      }),
    );
    await Future<void>.delayed(Duration.zero);
    await session.close();
    final seen = await events;
    expect(seen.whereType<QwenRealtimeReady>(), isNotEmpty);
    expect(seen.whereType<QwenRealtimeAudioDelta>().single.pcm, [9, 8, 7, 6]);
  });

  test('omni model uses slim session.update and workspace header', () async {
    final fake = _FakeSocket();
    Map<String, dynamic>? headersSeen;
    final session = QwenRealtimeSession(
      connect: (uri, {headers}) async {
        headersSeen = headers;
        expect(uri.queryParameters['model'], 'qwen3.8-omni-flash-realtime');
        return fake;
      },
    );
    const settings = QwenRealtimeSettings(
      base: 'wss://ws-17piqy1lazm81wox.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime',
      key: 'sk-testkey0123456789abcdef',
      model: 'qwen3.8-omni-flash-realtime',
      voice: 'Tina',
    );
    expect(settings.isOmniRealtime, isTrue);
    expect(settings.workspaceId, 'ws-17piqy1lazm81wox');
    final opening = session.open(settings);
    await Future<void>.delayed(Duration.zero);
    expect(headersSeen?['X-DashScope-WorkSpace'], 'ws-17piqy1lazm81wox');
    fake.incoming.add(jsonEncode({'type': 'session.created'}));
    await Future<void>.delayed(Duration.zero);
    final update = jsonDecode(fake.sent.single) as Map<String, dynamic>;
    final sessionBody = update['session'] as Map<String, dynamic>;
    expect(sessionBody['voice'], 'Tina');
    expect(sessionBody['modalities'], ['text', 'audio']);
    expect(sessionBody['input_audio_transcription'], {'model': 'qwen3-asr-flash-realtime'});
    expect(sessionBody['turn_detection'], {'type': 'server_vad', 'create_response': false});
    expect(sessionBody.containsKey('input_audio_format'), isFalse);
    expect(sessionBody.containsKey('audio'), isFalse);
    fake.incoming.add(jsonEncode({'type': 'session.updated'}));
    await opening;
    await session.close();
  });

  test('settings ready depends on call mode', () {
    expect(const QwenRealtimeSettings().ready, isFalse);
    expect(const QwenRealtimeSettings(key: 'k').ready, isTrue);
    expect(const QwenRealtimeSettings(key: 'k', mode: VoiceCallMode.turnBased).ready, isFalse);
    expect(
      const QwenRealtimeSettings(
        key: 'k',
        base: 'ws://192.168.1.10:8091/v1/realtime',
        mode: VoiceCallMode.cloudRealtime,
      ).ready,
      isFalse,
    );
  });

  test('LAN mode is ready without Bailian key', () {
    const s = QwenRealtimeSettings(
      base: 'ws://192.168.1.10:8091/v1/realtime',
      model: 'minicpm-o-4_5',
      mode: VoiceCallMode.lanHost,
    );
    expect(s.isLocalLan, isTrue);
    expect(s.ready, isTrue);
    expect(s.isOmniRealtime, isFalse);
    expect(s.workspaceId, isNull);
    expect(s.websocketUri?.scheme, 'ws');
    expect(s.websocketUri?.host, '192.168.1.10');
  });

  test('LAN open sends local bearer and PCM session.update', () async {
    final fake = _FakeSocket();
    Map<String, dynamic>? headersSeen;
    final session = QwenRealtimeSession(
      connect: (uri, {headers}) async {
        headersSeen = headers;
        expect(uri.scheme, 'ws');
        expect(uri.queryParameters['model'], 'minicpm-o-4_5');
        return fake;
      },
    );
    const settings = QwenRealtimeSettings(
      base: 'ws://10.0.0.2:8091/v1/realtime',
      model: 'minicpm-o-4_5',
      voice: 'default',
      mode: VoiceCallMode.lanHost,
    );
    final opening = session.open(settings);
    await Future<void>.delayed(Duration.zero);
    expect(headersSeen?['Authorization'], 'Bearer local');
    expect(headersSeen?.containsKey('X-DashScope-WorkSpace'), isFalse);
    fake.incoming.add(jsonEncode({'type': 'session.created'}));
    await Future<void>.delayed(Duration.zero);
    final update = jsonDecode(fake.sent.single) as Map<String, dynamic>;
    final body = update['session'] as Map<String, dynamic>;
    expect(body['input_audio_format'], 'pcm16');
    expect(body.containsKey('audio'), isTrue);
    expect(body['turn_detection'], containsPair('create_response', false));
    fake.incoming.add(jsonEncode({'type': 'session.updated'}));
    await opening;
    await session.close();
  });

  test('delegateToAgent false keeps auto cloud reply', () async {
    final fake = _FakeSocket();
    final session = QwenRealtimeSession(
      connect: (uri, {headers}) async => fake,
    );
    const settings = QwenRealtimeSettings(
      key: 'sk-testkey0123456789abcdef',
      model: 'qwen3.8-omni-flash-realtime',
    );
    final opening = session.open(settings, delegateToAgent: false);
    await Future<void>.delayed(Duration.zero);
    fake.incoming.add(jsonEncode({'type': 'session.created'}));
    await Future<void>.delayed(Duration.zero);
    final update = jsonDecode(fake.sent.single) as Map<String, dynamic>;
    final body = update['session'] as Map<String, dynamic>;
    expect(body['turn_detection'], {'type': 'server_vad'});
    expect(body['turn_detection'], isNot(contains('create_response')));
    fake.incoming.add(jsonEncode({'type': 'session.updated'}));
    await opening;
    await session.close();
  });

  test('defaults target Omni Realtime', () {
    const s = QwenRealtimeSettings();
    expect(s.model, 'qwen3.8-omni-flash-realtime');
    expect(s.voice, 'Tina');
    expect(s.isOmniRealtime, isTrue);
    expect(s.isLocalLan, isFalse);
  });

  test('sanitizeRealtimeKey strips whitespace', () {
    expect(sanitizeRealtimeKey(' sk-abc \n'), 'sk-abc');
  });

  test('realtimeKeyShapeHint flags oversized paste', () {
    expect(realtimeKeyShapeHint('sk-${'a' * 100}'), contains('too long'));
    expect(realtimeKeyShapeHint('sk-shortbutvalidkey123456'), isNull);
    expect(realtimeKeyShapeHint('', localLan: true), isNull);
  });
}
