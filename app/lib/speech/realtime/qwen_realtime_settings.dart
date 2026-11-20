// 设置 › 语音 › Qwen Realtime: 百炼云端或局域网本地网关全双工。Key 只存在本机。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../secrets/secure_storage.dart';

/// Omni Realtime needs a workspace host; keep the public DashScope URL as a
/// starting point and let settings (or the user) replace it with
/// `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime`
/// or a LAN gateway `ws://192.168.x.x:8091/v1/realtime`.
const qwenRealtimeDefaultBase = 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';

const qwenRealtimeDefaultModel = 'qwen3.8-omni-flash-realtime';

const qwenRealtimeDefaultVoice = 'Tina';

/// Bearer token sent when a LAN gateway has no API key configured.
const qwenRealtimeLocalBearer = 'local';

/// Suggested LAN endpoint placeholder (user replaces the host).
const qwenRealtimeDefaultLanBase = 'ws://192.168.1.10:8765/v1/realtime';

/// First-shipped defaults; migrate on load so old installs pick up Omni.
const qwenRealtimeLegacyDefaultModel = 'qwen-audio-3.1-realtime-flash';
const qwenRealtimeLegacyDefaultVoice = 'longanqian_v3.1';

/// Short phrase (小艺-style); long sentences are hard for background ASR.
const qwenRealtimeDefaultWakePhrase = '小助手';

/// How voice calls are wired. All three keep DSH as the agent brain when used
/// through the call page (turn-based via ChatCall; Realtime modes via delegate).
enum VoiceCallMode {
  /// Phone VAD → cloud/local ASR → DSH → App TTS.
  turnBased,

  /// Bailian Realtime VAD/ASR → DSH → App TTS.
  cloudRealtime,

  /// LAN host VAD/STT → DSH → App TTS.
  lanHost,
}

VoiceCallMode voiceCallModeFromName(String? raw) => switch (raw) {
  'turnBased' => VoiceCallMode.turnBased,
  'lanHost' => VoiceCallMode.lanHost,
  'cloudRealtime' => VoiceCallMode.cloudRealtime,
  _ => VoiceCallMode.cloudRealtime,
};

class QwenRealtimeSettings {
  const QwenRealtimeSettings({
    this.base = qwenRealtimeDefaultBase,
    this.key = '',
    this.model = qwenRealtimeDefaultModel,
    this.voice = qwenRealtimeDefaultVoice,
    this.mode = VoiceCallMode.cloudRealtime,
    this.wakeEnabled = false,
    this.wakePhrase = qwenRealtimeDefaultWakePhrase,
  });

  final String base;
  final String key;
  final String model;
  final String voice;

  /// Which of the three call schemes to use.
  final VoiceCallMode mode;

  /// Android: listen for [wakePhrase] in a mic FGS and open a Realtime call.
  final bool wakeEnabled;
  final String wakePhrase;

  /// Realtime transport is used for cloud and LAN modes.
  bool get enabled => mode != VoiceCallMode.turnBased;

  /// LAN / loopback gateway (cleartext `ws://` or private-IP `wss://`).
  /// Local mode does not require a Bailian `sk-` key.
  bool get isLocalLan {
    final uri = Uri.tryParse(base.trim());
    if (uri == null) return false;
    if (uri.scheme == 'ws') return true;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
    if (host.endsWith('.local')) return true;
    return _isPrivateIpv4(host);
  }

  /// True when the selected mode can start a Realtime-backed call.
  bool get ready {
    if (!enabled || model.trim().isEmpty || base.trim().isEmpty) return false;
    if (websocketUri == null) return false;
    switch (mode) {
      case VoiceCallMode.turnBased:
        return false;
      case VoiceCallMode.lanHost:
        return isLocalLan;
      case VoiceCallMode.cloudRealtime:
        return !isLocalLan && key.trim().isNotEmpty;
    }
  }

  /// Qwen-Omni Realtime (e.g. qwen3.8-omni-flash-realtime) uses a different
  /// session.update shape and usually a workspace-specific host.
  /// LAN gateways always use the PCM audio session shape instead.
  bool get isOmniRealtime {
    if (isLocalLan) return false;
    final m = model.trim().toLowerCase();
    return m.contains('omni') && m.contains('realtime');
  }

  /// Workspace id from a dedicated host like `ws-….cn-beijing.maas.aliyuncs.com`.
  String? get workspaceId {
    if (isLocalLan) return null;
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
    VoiceCallMode? mode,
    bool? wakeEnabled,
    String? wakePhrase,
  }) => QwenRealtimeSettings(
    base: base ?? this.base,
    key: key ?? this.key,
    model: model ?? this.model,
    voice: voice ?? this.voice,
    mode: mode ?? this.mode,
    wakeEnabled: wakeEnabled ?? this.wakeEnabled,
    wakePhrase: wakePhrase ?? this.wakePhrase,
  );
}

bool _looksLocalLanBase(String base) {
  final uri = Uri.tryParse(base.trim());
  if (uri == null) return false;
  if (uri.scheme == 'ws') return true;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
  if (host.endsWith('.local')) return true;
  return _isPrivateIpv4(host);
}

bool _isPrivateIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final nums = <int>[];
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return false;
    nums.add(n);
  }
  final a = nums[0];
  final b = nums[1];
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}

/// Strip copy/paste noise that causes 401 (spaces, newlines, BOM).
String sanitizeRealtimeKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), '').replaceAll('\uFEFF', '');

/// Soft shape check for Bailian keys (`sk-…`). Returns null when OK.
/// Skip for empty keys (LAN) or non-`sk-` local tokens.
String? realtimeKeyShapeHint(String value, {bool localLan = false}) {
  final key = sanitizeRealtimeKey(value);
  if (localLan) {
    if (key.isEmpty || key == qwenRealtimeLocalBearer) return null;
    // Allow any short shared token on LAN; only warn on Bailian-shaped mistakes.
    if (key.startsWith('sk-') && key.length > 80) {
      return 'API Key looks too long (len=${key.length}); paste only the sk-… value, not the CSV/URL';
    }
    return null;
  }
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
      final base = json is Map && json['base'] is String && (json['base'] as String).isNotEmpty
          ? json['base'] as String
          : qwenRealtimeDefaultBase;
      final mode = json is Map && json['mode'] is String
          ? voiceCallModeFromName(json['mode'] as String)
          : (json is Map && json['enabled'] == false
                ? VoiceCallMode.turnBased
                : (_looksLocalLanBase(base) ? VoiceCallMode.lanHost : VoiceCallMode.cloudRealtime));
      var next = QwenRealtimeSettings(
        base: base,
        model: json is Map && json['model'] is String && (json['model'] as String).isNotEmpty
            ? json['model'] as String
            : qwenRealtimeDefaultModel,
        voice: json is Map && json['voice'] is String && (json['voice'] as String).isNotEmpty
            ? json['voice'] as String
            : qwenRealtimeDefaultVoice,
        mode: mode,
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
        'mode': cleaned.mode.name,
        // Kept for older builds that only read the boolean.
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
