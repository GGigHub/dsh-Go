// Starts/stops Android wake FGS from Realtime settings; opens a call on match.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../speech/realtime/qwen_realtime_log.dart';
import '../../speech/realtime/qwen_realtime_settings.dart';
import '../../speech/realtime/realtime_keep.dart';
import '../../state/android_features.dart';
import '../../state/chat_state.dart';
import '../../state/hosts_state.dart' show activeHostProvider;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../chat/media/media_format.dart' show chatTitleShown;
import 'voice_call_page.dart';

/// Place under [HomeShell] so wake works wherever the person is in the app.
class RealtimeWakeHost extends ConsumerStatefulWidget {
  const RealtimeWakeHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RealtimeWakeHost> createState() => _RealtimeWakeHostState();
}

class _RealtimeWakeHostState extends ConsumerState<RealtimeWakeHost> {
  StreamSubscription<RealtimeKeepEvent>? _sub;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_syncWake()));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
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
        await keep.startWake(settings.wakePhrase);
      } else {
        await keep.stopWake();
      }
    } on Object catch (e) {
      realtimeLog('wake sync failed: $e');
    }
  }

  void _onKeepEvent(RealtimeKeepEvent event) {
    switch (event) {
      case RealtimeWakeEvent():
        unawaited(_openCall());
      case RealtimeHangUpEvent() || RealtimeWakeErrorEvent():
        break;
    }
  }

  Future<void> _openCall() async {
    if (!mounted || _opening) return;
    _opening = true;
    try {
      final settings = ref.read(qwenRealtimeSettingsProvider);
      if (!settings.ready) return;
      final l10n = context.l10n;
      final sessionId = ref.read(currentSessionProvider);
      final listed = sessionId == null ? null : ref.read(chatProvider(sessionId)).title;
      final title = listed != null && listed.trim().isNotEmpty
          ? chatTitleShown(listed.trim())
          : l10n.commonNewChat;
      final host = ref.read(activeHostProvider);
      final pinned = sessionId;
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
