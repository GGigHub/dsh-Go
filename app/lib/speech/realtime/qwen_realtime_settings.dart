// 设置 › 语音 › Qwen Realtime: App 直连百炼全双工通话。Key 只存在本机。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../secrets/secure_storage.dart';

/// Default DashScope Beijing realtime endpoint (override in settings if using
/// a workspace-specific host or Singapore).
const qwenRealtimeDefaultBase = 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';

const qwenRealtimeDefaultModel = 'qwen-audio-3.1-realtime-flash';

const qwenRealtimeDefaultVoice = 'longanqian_v3.1';

class QwenRealtimeSettings {
  const QwenRealtimeSettings({
    this.base = qwenRealtimeDefaultBase,
    this.key = '',
    this.model = qwenRealtimeDefaultModel,
    this.voice = qwenRealtimeDefaultVoice,
    this.enabled = true,
  });

  final String base;
  final String key;
  final String model;
  final String voice;

  /// When false, calls stay on the legacy turn-based path even if a key is set.
  final bool enabled;

  bool get ready => enabled && key.trim().isNotEmpty && model.trim().isNotEmpty && base.trim().isNotEmpty;

  Uri? get websocketUri {
    final trimmed = base.trim();
    if (trimmed.isEmpty || model.trim().isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'wss' && uri.scheme != 'ws')) return null;
    final params = Map<String, String>.from(uri.queryParameters);
    params['model'] = model.trim();
    return uri.replace(queryParameters: params);
  }

  QwenRealtimeSettings copyWith({
    String? base,
    String? key,
    String? model,
    String? voice,
    bool? enabled,
  }) => QwenRealtimeSettings(
    base: base ?? this.base,
    key: key ?? this.key,
    model: model ?? this.model,
    voice: voice ?? this.voice,
    enabled: enabled ?? this.enabled,
  );
}

class QwenRealtimeSettingsController extends Notifier<QwenRealtimeSettings> {
  static const _plainKey = 'speech_qwen_realtime_v1';
  static const _secretKey = 'speech_qwen_realtime_key';
  static const _secure = AppSecureStorage();
  late Future<void> _loaded;

  @override
  QwenRealtimeSettings build() {
    _loaded = _load();
    return const QwenRealtimeSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_plainKey);
      final json = raw == null ? null : jsonDecode(raw);
      var next = QwenRealtimeSettings(
        base: json is Map && json['base'] is String && (json['base'] as String).isNotEmpty
            ? json['base'] as String
            : qwenRealtimeDefaultBase,
        model: json is Map && json['model'] is String && (json['model'] as String).isNotEmpty
            ? json['model'] as String
            : qwenRealtimeDefaultModel,
        voice: json is Map && json['voice'] is String && (json['voice'] as String).isNotEmpty
            ? json['voice'] as String
            : qwenRealtimeDefaultVoice,
        enabled: json is! Map || json['enabled'] != false,
      );
      try {
        next = next.copyWith(key: await _secure.read(key: _secretKey) ?? '');
      } on Object {
        // No keystore: no key.
      }
      if (ref.mounted) state = next;
    } on Object {
      // Defaults for this run.
    }
  }

  Future<QwenRealtimeSettings> ready() async {
    await _loaded;
    return state;
  }

  Future<void> update(QwenRealtimeSettings next) async {
    await _loaded;
    if (!ref.mounted) return;
    final before = state;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _plainKey,
      jsonEncode({
        'base': next.base.trim().isEmpty ? qwenRealtimeDefaultBase : next.base.trim(),
        'model': next.model.trim().isEmpty ? qwenRealtimeDefaultModel : next.model.trim(),
        'voice': next.voice.trim().isEmpty ? qwenRealtimeDefaultVoice : next.voice.trim(),
        'enabled': next.enabled,
      }),
    );
    if (before.key != next.key) {
      try {
        final value = next.key.trim();
        if (value.isEmpty) {
          await _secure.delete(key: _secretKey);
        } else {
          await _secure.write(key: _secretKey, value: value);
        }
      } on Object {
        // Kept for this run only.
      }
    }
  }
}

final qwenRealtimeSettingsProvider = NotifierProvider<QwenRealtimeSettingsController, QwenRealtimeSettings>(
  QwenRealtimeSettingsController.new,
);
