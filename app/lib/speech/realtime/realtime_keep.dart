// Android microphone FGS bridge for Realtime call keep-alive and wake phrase.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/android_features.dart' show operatingSystemProvider;
import 'qwen_realtime_log.dart';

sealed class RealtimeKeepEvent {
  const RealtimeKeepEvent();
}

final class RealtimeWakeEvent extends RealtimeKeepEvent {
  const RealtimeWakeEvent({required this.phrase, this.heard = ''});
  final String phrase;
  final String heard;
}

final class RealtimeHangUpEvent extends RealtimeKeepEvent {
  const RealtimeHangUpEvent();
}

final class RealtimeWakeErrorEvent extends RealtimeKeepEvent {
  const RealtimeWakeErrorEvent(this.message);
  final String message;
}

class RealtimeKeep {
  RealtimeKeep([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/realtime_keep') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _events = StreamController<RealtimeKeepEvent>.broadcast();

  Stream<RealtimeKeepEvent> get events => _events.stream;

  Future<bool> supported() async {
    if (kIsWeb) return false;
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> startCallKeep({required String title, required String text}) async {
    realtimeLog('keep startCallKeep');
    await _channel.invokeMethod<void>('startCallKeep', {'title': title, 'text': text});
  }

  Future<void> stopCallKeep() async {
    realtimeLog('keep stopCallKeep');
    await _channel.invokeMethod<void>('stopCallKeep');
  }

  Future<void> startWake(String phrase) async {
    realtimeLog('keep startWake phraseLen=${phrase.trim().length}');
    await _channel.invokeMethod<void>('startWake', {'phrase': phrase.trim()});
  }

  Future<void> stopWake() async {
    realtimeLog('keep stopWake');
    await _channel.invokeMethod<void>('stopWake');
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'event') return;
    final args = call.arguments;
    if (args is! Map) return;
    final event = switch (args['type']) {
      'wake' => RealtimeWakeEvent(
        phrase: '${args['phrase'] ?? ''}',
        heard: '${args['heard'] ?? ''}',
      ),
      'hangUp' => const RealtimeHangUpEvent(),
      'wakeError' => RealtimeWakeErrorEvent('${args['message'] ?? 'wake error'}'),
      _ => null,
    };
    if (event != null) _events.add(event);
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }
}

final realtimeKeepProvider = Provider<RealtimeKeep>((ref) {
  final keep = RealtimeKeep();
  ref.onDispose(keep.dispose);
  return keep;
});

/// Android-only: wake / call-keep FGS. Other platforms no-op.
bool realtimeKeepAvailable(WidgetRef ref) => ref.watch(operatingSystemProvider) == 'android';
