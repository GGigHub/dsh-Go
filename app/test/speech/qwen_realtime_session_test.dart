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
  test('open sends session.update with pcm rates and appends base64 audio', () async {
    final fake = _FakeSocket();
    final session = QwenRealtimeSession(
      connect: (uri, {headers}) async {
        expect(uri.queryParameters['model'], 'qwen-audio-3.1-realtime-flash');
        expect(headers?['Authorization'], 'Bearer test-key');
        return fake;
      },
    );
    final events = session.events.toList();
    await session.open(
      const QwenRealtimeSettings(key: 'test-key', model: 'qwen-audio-3.1-realtime-flash'),
    );
    expect(fake.sent, isNotEmpty);
    final update = jsonDecode(fake.sent.first) as Map<String, dynamic>;
    expect(update['type'], 'session.update');
    fake.incoming.add(jsonEncode({'type': 'session.updated'}));
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

  test('settings ready requires key and enabled', () {
    expect(const QwenRealtimeSettings().ready, isFalse);
    expect(const QwenRealtimeSettings(key: 'k').ready, isTrue);
    expect(const QwenRealtimeSettings(key: 'k', enabled: false).ready, isFalse);
  });
}
