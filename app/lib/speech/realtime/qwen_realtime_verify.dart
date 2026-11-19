// Probe the current Realtime settings without starting a voice call.

import 'qwen_realtime_session.dart';
import 'qwen_realtime_settings.dart';

sealed class QwenRealtimeVerifyResult {
  const QwenRealtimeVerifyResult();
}

final class QwenRealtimeVerifyOk extends QwenRealtimeVerifyResult {
  const QwenRealtimeVerifyOk();
}

final class QwenRealtimeVerifyFailed extends QwenRealtimeVerifyResult {
  const QwenRealtimeVerifyFailed(this.message);
  final String message;
}

/// Opens a session through `session.updated`, then closes. Does not use the mic.
Future<QwenRealtimeVerifyResult> verifyQwenRealtime(QwenRealtimeSettings settings) async {
  final key = sanitizeRealtimeKey(settings.key);
  if (key.isEmpty) return const QwenRealtimeVerifyFailed('API Key is empty');
  final shape = realtimeKeyShapeHint(key);
  if (shape != null) return QwenRealtimeVerifyFailed(shape);
  if (settings.websocketUri == null) return const QwenRealtimeVerifyFailed('invalid endpoint');
  if (settings.isOmniRealtime && settings.workspaceId == null) {
    return const QwenRealtimeVerifyFailed(
      'Omni needs a workspace host: wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime',
    );
  }
  final session = QwenRealtimeSession();
  try {
    await session.open(settings.copyWith(key: key));
    await session.close();
    return const QwenRealtimeVerifyOk();
  } on Object catch (e) {
    try {
      await session.close();
    } on Object {
      // Already closed.
    }
    var message = '$e';
    if (message.startsWith('Bad state: ')) message = message.substring('Bad state: '.length);
    if (message.startsWith('StateError: ')) message = message.substring('StateError: '.length);
    return QwenRealtimeVerifyFailed(message);
  }
}
