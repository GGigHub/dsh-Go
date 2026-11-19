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

const qwenRealtimeDefaultWakePhrase = '你好小助手';

class QwenRealtimeSettings {
  const QwenRealtimeSettings({
    this.base = qwenRealtimeDefaultBase,
    this.key = '',
    this.model = qwenRealtimeDefaultModel,
    this.voice = qwenRealtimeDefaultVoice,
    this.enabled = true,
    this.wakeEnabled = false,
    this.wakePhrase = qwenRealtimeDefaultWakePhrase,
  });

  final String base;
  final String key;
  final String model;
  final String voice;

  /// When false, calls stay on the legacy turn-based path even if a key is set.
  final bool enabled;

  /// Android: listen for [wakePhrase] in a mic FGS and open a Realtime call.
  final bool wakeEnabled;
  final String wakePhrase;

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
    bool? wakeEnabled,
    String? wakePhrase,
  }) => QwenRealtimeSettings(
    base: base ?? this.base,
    key: key ?? this.key,
    model: model ?? this.model,
    voice: voice ?? this.voice,
    enabled: enabled ?? this.enabled,
    wakeEnabled: wakeEnabled ?? this.wakeEnabled,
    wakePhrase: wakePhrase ?? this.wakePhrase,
  );
}

/// Strip copy/paste noise that causes 401 (spaces, newlines, BOM).
String sanitizeRealtimeKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), '').replaceAll('\uFEFF', '');

/// Soft shape check for Bailian keys (`sk-…`). Returns null when OK.
String? realtimeKeyShapeHint(String value) {
  final key = sanitizeRealtimeKey(value);
  if (key.isEmpty) return 'API Key is empty';
  if (!key.startsWith('sk-')) return 'API Key should start with sk- (re-copy from Bailian console)';
  if (key.length < 20) return 'API Key looks too short (len=${key.length})';
  // Typical DashScope keys are ~35–50 chars; 100+ often means pasted URL/CSV junk.
  if (key.length > 80) {
    return 'API Key looks too long (len=${key.length}); paste only the sk-… value, not the CSV/URL';
  }
  if (!RegExp(r'^sk-[A-Za-z0-9._-]+$').hasMatch(key)) {
    return 'API Key has unexpected characters; re-copy from Bailian console';
  }
  return null;
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
        wakeEnabled: json is Map && json['wakeEnabled'] == true,
        wakePhrase: json is Map && json['wakePhrase'] is String && (json['wakePhrase'] as String).trim().isNotEmpty
            ? (json['wakePhrase'] as String).trim()
            : qwenRealtimeDefaultWakePhrase,
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
        'wakeEnabled': cleaned.wakeEnabled,
        'wakePhrase': cleaned.wakePhrase.trim().isEmpty
            ? qwenRealtimeDefaultWakePhrase
            : cleaned.wakePhrase.trim(),
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
