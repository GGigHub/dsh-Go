import 'package:dsh_app/speech/realtime/realtime_keep.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dsh/realtime_keep');
  final log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      log.add(call);
      if (call.method == 'supported') return true;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('start/stop call keep and wake go over the channel', () async {
    final keep = RealtimeKeep(channel);
    expect(await keep.supported(), isTrue);
    await keep.startCallKeep(title: 't', text: 'x');
    await keep.stopCallKeep();
    await keep.startWake('小助手');
    await keep.stopWake();
    expect(log.map((c) => c.method), [
      'supported',
      'startCallKeep',
      'stopCallKeep',
      'startWake',
      'stopWake',
    ]);
    expect(log[1].arguments, {'title': 't', 'text': 'x'});
    expect(log[3].arguments, {'phrase': '小助手'});
    keep.dispose();
  });

  test('consumePendingWake maps channel payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      log.add(call);
      if (call.method == 'consumePendingWake') {
        return {'phrase': '小助手', 'heard': '嘿小助手'};
      }
      return null;
    });
    final keep = RealtimeKeep(channel);
    final pending = await keep.consumePendingWake();
    expect(pending?.phrase, '小助手');
    expect(pending?.heard, '嘿小助手');
    keep.dispose();
  });

  test('channel events become typed keep events', () async {
    final keep = RealtimeKeep(channel);
    final seen = <RealtimeKeepEvent>[];
    final sub = keep.events.listen(seen.add);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('event', {'type': 'wake', 'phrase': 'hi', 'heard': 'say hi'}),
      ),
      (_) {},
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('event', {'type': 'hangUp'})),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(2));
    expect(seen[0], isA<RealtimeWakeEvent>());
    expect((seen[0] as RealtimeWakeEvent).phrase, 'hi');
    expect(seen[1], isA<RealtimeHangUpEvent>());
    await sub.cancel();
    keep.dispose();
  });
}
