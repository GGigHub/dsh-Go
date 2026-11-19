// Starts/stops Android wake FGS from Realtime settings; opens a call on match
// (小艺-style: wake → voice call page).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../speech/realtime/qwen_realtime_log.dart';
import '../../speech/realtime/qwen_realtime_settings.dart';
import '../../speech/realtime/realtime_keep.dart';
import '../../state/android_features.dart';
import '../../state/chat_state.dart';
import '../../state/hosts_state.dart' show activeHostProvider;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../../state/voice_state.dart' show voiceBridgeProvider;
import '../chat/media/media_format.dart' show chatTitleShown;
import '../chat/voice/voice_bridge.dart' show VoicePermission;
import '../common/brief_notice.dart';
import 'voice_call_page.dart';

/// Place under [HomeShell] so wake works wherever the person is in the app.
class RealtimeWakeHost extends ConsumerStatefulWidget {
  const RealtimeWakeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RealtimeWakeHost> createState() => _RealtimeWakeHostState();
}

class _RealtimeWakeHostState extends ConsumerState<RealtimeWakeHost> with WidgetsBindingObserver {
  StreamSubscription<RealtimeKeepEvent>? _sub;
  bool _opening = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_bootstrap()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
    }
  }

  Future<void> _bootstrap() async {
    await _syncWake();
    await _drainPendingWake();
  }

  Future<void> _onResumed() async {
    await _drainPendingWake();
    // OEM may have killed the FGS; re-assert if settings still want it.
    await _syncWake();
  }

  Future<void> _drainPendingWake() async {
    if (!mounted) return;
    if (ref.read(operatingSystemProvider) != 'android') return;
    final pending = await ref.read(realtimeKeepProvider).consumePendingWake();
    if (pending != null) unawaited(_openCall(from: 'pending'));
  }

  Future<void> _syncWake() async {
    if (!mounted) return;
    if (ref.read(operatingSystemProvider) != 'android') return;
    final keep = ref.read(realtimeKeepProvider);
    final settings = await ref.read(qwenRealtimeSettingsProvider.notifier).ready();
    if (!mounted) return;
    _sub ??= keep.events.listen(_onKeepEvent);
    final want = settings.ready && settings.wakeEnabled && settings.wakePhrase.trim().isNotEmpty;
    try {
      if (want) {
        final permission = await ref.read(voiceBridgeProvider).requestPermission();
        if (!mounted) return;
        if (permission != VoicePermission.granted) {
          realtimeLog('wake sync skipped: mic permission=$permission');
          await keep.stopWake();
          _notice(appL10n.speechRealtimeWakeNeedMic);
          return;
        }
        await keep.startWake(settings.wakePhrase);
        final running = await keep.wakeRunning();
        realtimeLog('wake sync started running=$running');
      } else {
        await keep.stopWake();
      }
    } on Object catch (e) {
      realtimeLog('wake sync failed: $e');
      _notice(appL10n.speechRealtimeWakeFailed('$e'));
    }
  }

  void _onKeepEvent(RealtimeKeepEvent event) {
    switch (event) {
      case RealtimeWakeEvent():
        // Clear sticky pending so a later resume does not open a second call.
        unawaited(() async {
          await ref.read(realtimeKeepProvider).consumePendingWake();
          await _openCall(from: 'event');
        }());
      case RealtimeWakeErrorEvent(:final message):
        if (_lastError == message) break;
        _lastError = message;
        realtimeLog('wake error: $message');
        _notice(appL10n.speechRealtimeWakeFailed(message));
      case RealtimeHangUpEvent():
        break;
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    showBriefNotice(context, text);
  }

  Future<void> _openCall({required String from}) async {
    if (!mounted || _opening || VoiceCallPage.isOpen) {
      realtimeLog('wake open skipped opening=$_opening callOpen=${VoiceCallPage.isOpen}');
      return;
    }
    _opening = true;
    try {
      final settings = await ref.read(qwenRealtimeSettingsProvider.notifier).ready();
      if (!mounted) return;
      if (!settings.ready) {
        _notice(appL10n.speechRealtimeWakeNeedRealtime);
        return;
      }
      realtimeLog('wake open call from=$from');
      HapticFeedback.mediumImpact();
      final l10n = context.l10n;
      final sessionId = ref.read(currentSessionProvider);
      final listed = sessionId == null ? null : ref.read(chatProvider(sessionId)).title;
      final title = listed != null && listed.trim().isNotEmpty
          ? chatTitleShown(listed.trim())
          : l10n.commonNewChat;
      final host = ref.read(activeHostProvider);
      final pinned = sessionId;
      // Wait a frame so bring-to-front has a settled navigator.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted || VoiceCallPage.isOpen) return;
      await openChatCall(
        context,
        title: title,
        session: () async {
          if (!mounted || ref.read(activeHostProvider) != host) return null;
          return pinned;
        },
      );
    } on Object catch (e) {
      realtimeLog('wake open call failed: $e');
      _notice(appL10n.speechRealtimeWakeFailed('$e'));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(qwenRealtimeSettingsProvider, (_, _) => unawaited(_syncWake()));
    return widget.child;
  }
}
