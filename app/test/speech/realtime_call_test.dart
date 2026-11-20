import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/speech/call/realtime_call.dart';
import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/realtime/qwen_realtime_session.dart';
import 'package:dsh_app/speech/realtime/qwen_realtime_settings.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/voice/streaming_pcm.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'speech_fakes.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel pcmChannel;
  late StreamController<dynamic> platformEvents;

  setUp(() {
    pcmChannel = const MethodChannel('dsh/voice');
    platformEvents = StreamController<dynamic>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pcmChannel, (
      call,
    ) async {
      expect(call.method, 'streamingPcm');
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pcmChannel, null);
    await platformEvents.close();
  });

  test('transcript goes to DSH conversation; agent reply is spoken', () async {
    final fake = _FakeSocket();
    final audio = FakeAudio();
    final conversation = FakeConversation();
    final outs = <FakeOut>[];
    final pcm = StreamingPcmCapture(channel: pcmChannel, platformEvents: platformEvents.stream);
    final call = RealtimeCallController(
      audio: audio,
      pcm: pcm,
      settings: const QwenRealtimeSettings(key: 'sk-testkey0123456789abcdef'),
      conversation: conversation,
      voice: () {
        final out = FakeOut();
        outs.add(out);
        return out;
      },
      choices: () async => (bargeIn: true, speaker: true, spokenHint: '（语音通话）', pause: CallPause.normal),
      cutNote: (heard) => '（被打断在：$heard）',
      sessionFactory: () => QwenRealtimeSession(connect: (uri, {headers}) async => fake),
      cueAfter: const Duration(days: 1),
    );

    final started = call.start();
    await pumpEventQueue();
    fake.incoming.add(jsonEncode({'type': 'session.created'}));
    await pumpEventQueue();
    final update = jsonDecode(fake.sent.single) as Map<String, dynamic>;
    expect((update['session'] as Map)['turn_detection'], containsPair('create_response', false));
    fake.incoming.add(jsonEncode({'type': 'session.updated'}));
    await started;
    await pumpEventQueue();
    expect(call.phase, CallPhase.listening);

    fake.incoming.add(jsonEncode({'type': 'input_audio_buffer.speech_started'}));
    await pumpEventQueue();
    expect(call.phase, CallPhase.hearing);
    fake.incoming.add(jsonEncode({'type': 'input_audio_buffer.speech_stopped'}));
    await pumpEventQueue();
    fake.incoming.add(
      jsonEncode({
        'type': 'conversation.item.input_audio_transcription.completed',
        'transcript': '帮我看看今天的任务',
      }),
    );
    await pumpEventQueue();
    expect(conversation.sent, ['（语音通话）\n帮我看看今天的任务']);
    expect(call.phase, CallPhase.thinking);
    expect(call.turns.single.you, '帮我看看今天的任务');

    conversation.reply('好的，我先打开待办');
    await pumpEventQueue();
    expect(outs, isNotEmpty);
    expect(outs.single.added, ['好的，我先打开待办']);
    outs.single.emit(const SpeechOutStarted());
    await pumpEventQueue();
    expect(call.phase, CallPhase.speaking);

    conversation.reply('好的，我先打开待办。一共三件。', done: true);
    await pumpEventQueue();
    expect(outs.single.finished, isTrue);
    outs.single.emit(const SpeechOutDone());
    await pumpEventQueue();
    expect(call.phase, CallPhase.listening);

    call.hangUp();
    await pumpEventQueue();
    call.dispose();
    await pcm.dispose();
  });

  test('barge-in interrupts the agent turn', () async {
    final fake = _FakeSocket();
    final audio = FakeAudio();
    final conversation = FakeConversation();
    final outs = <FakeOut>[];
    final pcm = StreamingPcmCapture(channel: pcmChannel, platformEvents: platformEvents.stream);
    final call = RealtimeCallController(
      audio: audio,
      pcm: pcm,
      settings: const QwenRealtimeSettings(key: 'sk-testkey0123456789abcdef'),
      conversation: conversation,
      voice: () {
        final out = FakeOut()..heard = '已经开始了';
        outs.add(out);
        return out;
      },
      choices: () async => (bargeIn: true, speaker: true, spokenHint: null, pause: CallPause.normal),
      cutNote: (heard) => '（被打断在：$heard）',
      sessionFactory: () => QwenRealtimeSession(connect: (uri, {headers}) async => fake),
      cueAfter: const Duration(days: 1),
    );

    final started = call.start();
    await pumpEventQueue();
    fake.incoming.add(jsonEncode({'type': 'session.created'}));
    await pumpEventQueue();
    fake.incoming.add(jsonEncode({'type': 'session.updated'}));
    await started;
    await pumpEventQueue();

    fake.incoming.add(
      jsonEncode({'type': 'conversation.item.input_audio_transcription.completed', 'transcript': '继续'}),
    );
    await pumpEventQueue();
    conversation.reply('很长的一段回复');
    await pumpEventQueue();
    outs.single.emit(const SpeechOutStarted());
    await pumpEventQueue();
    expect(call.phase, CallPhase.speaking);

    fake.incoming.add(jsonEncode({'type': 'input_audio_buffer.speech_started'}));
    await pumpEventQueue();
    expect(conversation.interrupts, 1);
    expect(outs.single.stopped, isTrue);
    expect(call.phase, CallPhase.hearing);

    fake.incoming.add(
      jsonEncode({'type': 'conversation.item.input_audio_transcription.completed', 'transcript': '停一下'}),
    );
    await pumpEventQueue();
    expect(conversation.sent.last, contains('（被打断在：已经开始了）'));
    expect(conversation.sent.last, endsWith('停一下'));

    call.hangUp();
    await pumpEventQueue();
    call.dispose();
    await pcm.dispose();
  });
}
