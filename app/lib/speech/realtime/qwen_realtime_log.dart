// Diagnostic logs for Qwen Realtime. Safe for logcat: never prints full API keys.

import 'package:flutter/foundation.dart';

/// Always on in debug/profile builds so a debug APK can be grepped via:
/// `adb logcat -s flutter | grep dsh.realtime`
/// or `adb logcat | findstr dsh.realtime`
void realtimeLog(String message) {
  if (kReleaseMode) return;
  final ts = DateTime.now().toIso8601String();
  debugPrint('[dsh.realtime] $ts $message');
}

/// Mask a secret: prefix…suffix + length. Empty → "(empty)".
String realtimeMaskSecret(String value) {
  final t = value.trim();
  if (t.isEmpty) return '(empty)';
  if (t.length <= 8) return 'len=${t.length}';
  return '${t.substring(0, 4)}…${t.substring(t.length - 4)} (len=${t.length})';
}
