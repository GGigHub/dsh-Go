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

  test('start/stop call keep go over the channel', () async {
    final keep = RealtimeKeep(channel);
    expect(await keep.supported(), isTrue);
    await keep.startCallKeep(title: 't', text: 'x');
    await keep.stopCallKeep();
    expect(log.map((c) => c.method), ['supported', 'startCallKeep', 'stopCallKeep']);
    expect(log[1].arguments, {'title': 't', 'text': 'x'});
    keep.dispose();
  });

  test('hangUp channel events become typed keep events', () async {
    final keep = RealtimeKeep(channel);
    final seen = <RealtimeKeepEvent>[];
    final sub = keep.events.listen(seen.add);
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('event', {'type': 'hangUp'})),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(1));
    expect(seen[0], isA<RealtimeHangUpEvent>());
    await sub.cancel();
    keep.dispose();
  });
}
