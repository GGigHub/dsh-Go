// Full-duplex mic/VAD/ASR via Qwen Realtime; brain is the DSH chat path
// ([CallConversation]): context, memory and tools stay with the agent.
// Cloud Omni does not auto-reply (`create_response: false`); replies are read
// with the same [SpeechOut] path as the turn-based call.

import 'dart:async';
import 'dart:typed_data';

import '../../voice/streaming_pcm.dart';
import '../realtime/qwen_realtime_log.dart';
import '../realtime/qwen_realtime_session.dart';
import '../realtime/qwen_realtime_settings.dart';
import '../realtime/realtime_keep.dart';
import '../speech_audio.dart';
import '../speech_out.dart';
import 'voice_call.dart';

class RealtimeCallController extends CallController {
  RealtimeCallController({
    required this.audio,
    required this.pcm,
    required this.settings,
    required this.conversation,
    required this.voice,
    required this.choices,
    this.permission,
    this.cutNote,
    this.thinkingCue,
    this.sessionFactory,
    this.cueAfter = const Duration(milliseconds: 1200),
    this.keep,
    this.keepTitle = 'Voice call',
    this.keepText = 'Realtime call in progress',
  });

  final SpeechAudio audio;
  final StreamingPcmCapture pcm;
  final QwenRealtimeSettings settings;
  final CallConversation conversation;
  final SpeechOut Function() voice;
  final Future<CallChoices> Function() choices;
  final Future<bool> Function()? permission;
  final String Function(String heard)? cutNote;
  final Future<void> Function()? thinkingCue;
  final QwenRealtimeSession Function()? sessionFactory;
  final Duration cueAfter;
  final RealtimeKeep? keep;
  final String keepTitle;
  final String keepText;

  QwenRealtimeSession? _session;
  StreamSubscription<QwenRealtimeEvent>? _sessionSub;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<SpeechAudioEvent>? _audioSub;
  StreamSubscription<CallReply>? _replySub;
  StreamSubscription<SpeechOutEvent>? _outSub;

  CallPhase _phase = CallPhase.starting;
  CallEnd? _ended;
  bool _muted = false;
  bool _speaker = true;
  bool _bargeIn = true;
  bool _asking = false;
  bool _disposed = false;
  double _micLevel = 0;
  double _voiceLevel = 0;
  String _heard = '';
  String _live = '';
  String _reply = '';
  String _said = '';
  Object? _error;
  String? _spokenHint;
  bool _hinted = false;
  String? _cutAt;
  bool _replyDone = true;
  bool _cued = false;
  bool _voiced = false;
  int _turn = 0;
  int _spoken = 0;
  Timer? _cueTimer;
  SpeechOut? _out;
  final _turns = <CallTurn>[];

  @override
  CallPhase get phase => _phase;
  @override
  CallEnd? get ended => _ended;
  @override
  bool get muted => _muted;
  @override
  bool get speaker => _speaker;
  @override
  double get micLevel => _micLevel;
  @override
  double get voiceLevel => _voiceLevel;
  @override
  String get heard => (_phase == CallPhase.hearing || _live.isNotEmpty) && _live.isNotEmpty ? _live : _heard;
  @override
  String get caption => _said.isNotEmpty ? _said : _reply;
  @override
  bool get cueStill => !_voiced && _spoken == 0 && !_replyDone && _phase == CallPhase.thinking;
  @override
  Object? get error => _error;
  @override
  List<CallTurn> get turns => List.unmodifiable(_turns);
  @override
  bool get asking => _asking;

  @override
  Future<void> start() async {
    realtimeLog(
      'call start delegateToAgent=true localLan=${settings.isLocalLan} model=${settings.model} '
      'base=${settings.base} voice=${settings.voice} '
      'key=${realtimeMaskSecret(settings.key)} ready=${settings.ready}',
    );
    final chosen = await choices();
    if (_disposed || _phase == CallPhase.ended) return;
    _bargeIn = chosen.bargeIn;
    _speaker = chosen.speaker;
    _spokenHint = chosen.spokenHint;
    notifyListeners();

    final ask = permission;
    if (ask != null) {
      _asking = true;
      final granted = await ask().catchError((Object _) => false);
      _asking = false;
      realtimeLog('mic permission granted=$granted');
      if (_disposed || _phase == CallPhase.ended) return;
      if (!granted) {
        _end(CallEnd.permission);
        return;
      }
    }

    _replySub = conversation.replies.listen(_onReply);
    final session = (sessionFactory ?? QwenRealtimeSession.new)();
    _session = session;
    _sessionSub = session.events.listen(_onSession, onError: (_) => _end(CallEnd.failed));
    try {
      await session.open(settings, delegateToAgent: true);
    } catch (error) {
      realtimeLog('session.open threw: $error');
      _error = error is TimeoutException || error is StateError || error is ArgumentError
          ? error.toString()
          : error;
      _end(CallEnd.failed);
      return;
    }
    if (_disposed || _phase == CallPhase.ended) return;

    final started = await audio.startCall(bargeIn: false, pause: CallPause.patient);
    realtimeLog('audio.startCall → $started');
    if (_disposed || _phase == CallPhase.ended) {
      if (started == CallStart.ok) unawaited(audio.stopCall());
      return;
    }
    switch (started) {
      case CallStart.ok:
        _speaker = await audio.speaker(_speaker);
        _audioSub = audio.events.listen(_onAudio);
        try {
          await pcm.start(StreamingPcmSource.call);
          realtimeLog('pcm.start ok');
        } on Object catch (e) {
          realtimeLog('pcm.start failed: $e');
          _end(CallEnd.microphone);
          return;
        }
        var frames = 0;
        _pcmSub = pcm.frames.listen((frame) {
          if (_muted || _phase == CallPhase.ended) return;
          frames++;
          if (frames == 1 || frames % 100 == 0) {
            realtimeLog('pcm frame #$frames bytes=${frame.length} phase=$_phase muted=$_muted');
          }
          _session?.appendPcm(frame);
        });
        unawaited(_startKeep());
        _set(CallPhase.listening);
      case CallStart.permission:
        _end(CallEnd.permission);
      case CallStart.microphone || CallStart.unavailable:
        _end(CallEnd.microphone);
    }
  }

  Future<void> _startKeep() async {
    final bridge = keep;
    if (bridge == null) return;
    try {
      await bridge.startCallKeep(title: keepTitle, text: keepText);
    } on Object catch (e) {
      realtimeLog('call keep failed: $e');
    }
  }

  void _onAudio(SpeechAudioEvent event) {
    if (_phase == CallPhase.ended) return;
    switch (event) {
      case MicLevel(:final value):
        _micLevel = value;
        notifyListeners();
      case PlayLevel(:final value):
        // Agent TTS levels come from SpeechOut; ignore leftover PCM play levels.
        if (_out == null) {
          _voiceLevel = value;
          notifyListeners();
        }
      case PlayEvent() || SpeechStart() || Utterance() || CallError():
        break;
    }
  }

  void _onSession(QwenRealtimeEvent event) {
    if (_phase == CallPhase.ended) return;
    switch (event) {
      case QwenRealtimeReady():
        if (_phase == CallPhase.starting) _set(CallPhase.listening);
      case QwenRealtimeSpeechStarted():
        _live = '';
        if (_bargeIn && (_phase == CallPhase.speaking || _phase == CallPhase.thinking)) {
          _cutIn();
        }
        _set(CallPhase.hearing);
      case QwenRealtimeSpeechStopped():
        if (_live.isNotEmpty) _heard = _live;
        if (_phase == CallPhase.hearing) _set(CallPhase.thinking);
      case QwenRealtimeInputDelta(:final text):
        _live = (_live + text).trim();
        notifyListeners();
      case QwenRealtimeInputFinal(:final text):
        final said = text.trim().isEmpty ? _live.trim() : text.trim();
        if (said.isNotEmpty) {
          _heard = said;
          _live = '';
          notifyListeners();
          unawaited(_sendToAgent(said));
        } else if (_phase == CallPhase.thinking || _phase == CallPhase.hearing) {
          _set(CallPhase.listening);
        }
      case QwenRealtimeResponseStarted(:final responseId):
        // Should not happen with create_response:false; cancel stray cloud replies.
        realtimeLog('unexpected cloud response.created id=$responseId → cancel');
        _session?.cancelResponse();
      case QwenRealtimeOutputDelta() ||
          QwenRealtimeOutputFinal() ||
          QwenRealtimeAudioDelta() ||
          QwenRealtimeResponseDone() ||
          QwenRealtimeCleared():
        break;
      case QwenRealtimeError(:final message):
        realtimeLog('session event error: $message');
        _error = message;
        notifyListeners();
        _end(CallEnd.failed);
      case QwenRealtimeClosed():
        if (_phase != CallPhase.ended) {
          realtimeLog('session closed unexpectedly phase=$_phase');
          _end(CallEnd.failed);
        }
    }
  }

  Future<void> _sendToAgent(String said) async {
    if (_phase == CallPhase.ended || _disposed) return;
    _turns.add(CallTurn(said));
    _reply = '';
    _said = '';
    _voiced = false;
    _spoken = 0;
    _turn++;
    _replyDone = false;
    final hint = _spokenHint;
    final cut = _cutAt;
    _cutAt = null;
    final note = cut == null ? null : cutNote?.call(cut.length > 30 ? '…${cut.substring(cut.length - 30)}' : cut);
    final message = [if (!_hinted && hint != null) hint, ?note, said].join('\n');
    _hinted = true;
    _cued = false;
    _cueTimer?.cancel();
    _cueTimer = Timer(cueAfter, _cue);
    _set(CallPhase.thinking);
    realtimeLog('delegate send len=${message.length} turn=$_turn');
    final sent = await conversation.send(message);
    if (_phase == CallPhase.ended || _disposed) return;
    if (!sent) {
      _replyDone = true;
      _cueTimer?.cancel();
      _error = const CallSendFailed();
      realtimeLog('delegate send failed');
      _set(CallPhase.listening);
    }
  }

  void _onReply(CallReply reply) {
    if (_phase == CallPhase.ended || _replyDone) return;
    final text = reply.text;
    if (text.length > _spoken) {
      final out = _out ??= _newVoice();
      out.add(text.substring(_spoken));
      _spoken = text.length;
      _reply = text;
      if (_turns.isNotEmpty) _turns.last = CallTurn(_turns.last.you, her: text);
      notifyListeners();
    }
    if (reply.done) {
      _replyDone = true;
      _cueTimer?.cancel();
      final out = _out;
      if (out == null) {
        if (_phase == CallPhase.thinking) _set(CallPhase.listening);
      } else {
        out.finish();
      }
    }
  }

  void _cutIn() {
    realtimeLog('barge-in interrupt phase=$_phase');
    final out = _out;
    if (out != null) {
      _cutAt = out.heard;
      if (_turns.isNotEmpty && _turns.last.her.isNotEmpty) {
        _turns.last = CallTurn(_turns.last.you, her: out.heard, cut: true);
      }
      _stopVoice();
    }
    if (!_replyDone) unawaited(conversation.interrupt());
    _replyDone = true;
    _cueTimer?.cancel();
    _session?.cancelResponse();
  }

  void _cue() {
    if (_cued || !cueStill) return;
    _cued = true;
    unawaited(thinkingCue?.call());
  }

  SpeechOut _newVoice() {
    final out = voice();
    final turn = _turn;
    _outSub = out.events.listen((event) {
      if (!identical(_out, out) || _phase == CallPhase.ended) return;
      switch (event) {
        case SpeechOutStarted():
          _voiced = true;
          _cueTimer?.cancel();
          if (_phase == CallPhase.thinking || _phase == CallPhase.listening) _set(CallPhase.speaking);
        case SpeechOutLevel(:final value):
          _voiceLevel = value;
          _said = out.heard;
          notifyListeners();
        case SpeechOutDone():
          _said = out.heard;
          _clearVoice(out);
          if (_phase == CallPhase.speaking || (_phase == CallPhase.thinking && turn == _turn && _replyDone)) {
            _set(CallPhase.listening);
          }
        case SpeechOutFailed(:final error):
          _clearVoice(out);
          _voiced = false;
          _error = error;
          if (_phase == CallPhase.speaking || _phase == CallPhase.thinking) _set(CallPhase.listening);
      }
    });
    return out;
  }

  void _clearVoice(SpeechOut out) {
    if (!identical(_out, out)) return;
    _out = null;
    unawaited(_outSub?.cancel());
    _outSub = null;
    _voiceLevel = 0;
  }

  void _stopVoice() {
    final out = _out;
    if (out == null) return;
    _clearVoice(out);
    out.stop();
  }

  @override
  void hangUp() => _end(CallEnd.hungUp);

  @override
  void backgrounded() {
    // Realtime keeps the mic via FGS; leaving the screen must not hang up.
    realtimeLog('backgrounded ignored (call keep)');
  }

  @override
  void setMuted(bool on) {
    if (_phase == CallPhase.ended || on == _muted) return;
    _muted = on;
    unawaited(audio.mute(on));
    notifyListeners();
  }

  @override
  Future<void> setSpeaker(bool on) async {
    if (_phase == CallPhase.ended) return;
    _speaker = await audio.speaker(on);
    notifyListeners();
  }

  @override
  void skip() {
    if (_phase != CallPhase.speaking && _phase != CallPhase.thinking) return;
    _cutIn();
    _set(CallPhase.listening);
  }

  @override
  void live(String text) {
    // Cloud transcription owns captions in realtime mode.
  }

  @override
  Future<void> refreshRecognizer() async {}

  @override
  void setPause(CallPause pause) {}

  void _end(CallEnd why) {
    if (_phase == CallPhase.ended) return;
    realtimeLog('call end reason=$why error=$_error');
    _ended = why;
    _phase = CallPhase.ended;
    unawaited(_tearDown());
    notifyListeners();
  }

  Future<void> _tearDown() async {
    _disposed = true;
    _cueTimer?.cancel();
    _replyDone = true;
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _sessionSub?.cancel();
    _sessionSub = null;
    await _replySub?.cancel();
    _replySub = null;
    _stopVoice();
    await pcm.stop();
    await audio.stopCall();
    await _session?.close();
    _session = null;
    try {
      await keep?.stopCallKeep();
    } on Object catch (e) {
      realtimeLog('stopCallKeep failed: $e');
    }
  }

  void _set(CallPhase phase) {
    if (_phase == phase || _phase == CallPhase.ended) return;
    realtimeLog('phase $_phase → $phase');
    _phase = phase;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_phase != CallPhase.ended) _end(CallEnd.hungUp);
    conversation.dispose();
    super.dispose();
  }
}
