// 设置 › 语音 › Qwen Realtime: App 直连百炼全双工通话。Key 只存在本机。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../secrets/secure_storage.dart';

/// Omni Realtime needs a workspace host; keep the public DashScope URL as a
/// starting point and let settings (or the user) replace it with
/// `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime`.
const qwenRealtimeDefaultBase = 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';

const qwenRealtimeDefaultModel = 'qwen3.8-omni-flash-realtime';

const qwenRealtimeDefaultVoice = 'Tina';

/// First-shipped defaults; migrate on load so old installs pick up Omni.
const qwenRealtimeLegacyDefaultModel = 'qwen-audio-3.1-realtime-flash';
const qwenRealtimeLegacyDefaultVoice = 'longanqian_v3.1';

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

  /// Qwen-Omni Realtime (e.g. qwen3.8-omni-flash-realtime) uses a different
  /// session.update shape and usually a workspace-specific host.
  bool get isOmniRealtime {
    final m = model.trim().toLowerCase();
    return m.contains('omni') && m.contains('realtime');
  }

  /// Workspace id from a dedicated host like `ws-….cn-beijing.maas.aliyuncs.com`.
  String? get workspaceId {
    final host = Uri.tryParse(base.trim())?.host;
    if (host == null || !host.endsWith('.maas.aliyuncs.com')) return null;
    final id = host.split('.').first;
    return id.startsWith('ws-') ? id : null;
  }

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

/// Strip copy/paste noise that causes 401 (spaces, newlines, BOM).
String sanitizeRealtimeKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), '').replaceAll('\uFEFF', '');

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
      // Bump first-shipped Audio defaults to Omni so users who only paste a Key work.
      if (next.model == qwenRealtimeLegacyDefaultModel) {
        next = next.copyWith(model: qwenRealtimeDefaultModel);
      }
      if (next.voice == qwenRealtimeLegacyDefaultVoice) {
        next = next.copyWith(voice: qwenRealtimeDefaultVoice);
      }
      try {
        next = next.copyWith(key: sanitizeRealtimeKey(await _secure.read(key: _secretKey) ?? ''));
      } on Object {
        // No keystore: no key.
      }
      if (ref.mounted) {
        state = next;
        // Persist migration so the next launch stays on Omni.
        if (json is Map &&
            (json['model'] == qwenRealtimeLegacyDefaultModel || json['voice'] == qwenRealtimeLegacyDefaultVoice)) {
          unawaited(update(next));
        }
      }
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
    final cleaned = next.copyWith(key: sanitizeRealtimeKey(next.key));
    final before = state;
    state = cleaned;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _plainKey,
      jsonEncode({
        'base': cleaned.base.trim().isEmpty ? qwenRealtimeDefaultBase : cleaned.base.trim(),
        'model': cleaned.model.trim().isEmpty ? qwenRealtimeDefaultModel : cleaned.model.trim(),
        'voice': cleaned.voice.trim().isEmpty ? qwenRealtimeDefaultVoice : cleaned.voice.trim(),
        'enabled': cleaned.enabled,
      }),
    );
    if (before.key != cleaned.key) {
      try {
        final value = cleaned.key;
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
