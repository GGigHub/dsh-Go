// Full-duplex voice call via Qwen-Audio Realtime (App ↔ DashScope).
// Reuses the call page shell; does not send turns through the DSH chat path.

import 'dart:async';
import 'dart:typed_data';

import '../../voice/streaming_pcm.dart';
import '../realtime/qwen_realtime_log.dart';
import '../realtime/qwen_realtime_session.dart';
import '../realtime/qwen_realtime_settings.dart';
import '../speech_audio.dart';
import 'voice_call.dart';

class RealtimeCallController extends CallController {
  RealtimeCallController({
    required this.audio,
    required this.pcm,
    required this.settings,
    required this.choices,
    this.permission,
    this.sessionFactory,
  });

  final SpeechAudio audio;
  final StreamingPcmCapture pcm;
  final QwenRealtimeSettings settings;
  final Future<CallChoices> Function() choices;
  final Future<bool> Function()? permission;
  final QwenRealtimeSession Function()? sessionFactory;

  QwenRealtimeSession? _session;
  StreamSubscription<QwenRealtimeEvent>? _sessionSub;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<SpeechAudioEvent>? _audioSub;

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
  String? _playId;
  String? _responseId;
  final _turns = <CallTurn>[];
  String _turnYou = '';

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
  bool get cueStill => false;
  @override
  Object? get error => _error;
  @override
  List<CallTurn> get turns => List.unmodifiable(_turns);
  @override
  bool get asking => _asking;

  @override
  Future<void> start() async {
    realtimeLog(
      'call start localLan=${settings.isLocalLan} model=${settings.model} '
      'base=${settings.base} voice=${settings.voice} '
      'key=${realtimeMaskSecret(settings.key)} ready=${settings.ready}',
    );
    final chosen = await choices();
    if (_disposed || _phase == CallPhase.ended) return;
    _bargeIn = chosen.bargeIn;
    _speaker = chosen.speaker;
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

    final session = (sessionFactory ?? QwenRealtimeSession.new)();
    _session = session;
    _sessionSub = session.events.listen(_onSession, onError: (_) => _end(CallEnd.failed));
    try {
      await session.open(settings);
    } catch (error) {
      realtimeLog('session.open threw: $error');
      _error = error is TimeoutException || error is StateError || error is ArgumentError
          ? error.toString()
          : error;
      _end(CallEnd.failed);
      return;
    }
    if (_disposed || _phase == CallPhase.ended) return;

    // Native barge-in off: the cloud VAD owns turn-taking; we still need the mic.
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
        _set(CallPhase.listening);
      case CallStart.permission:
        _end(CallEnd.permission);
      case CallStart.microphone || CallStart.unavailable:
        _end(CallEnd.microphone);
    }
  }

  void _onAudio(SpeechAudioEvent event) {
    if (_phase == CallPhase.ended) return;
    switch (event) {
      case MicLevel(:final value):
        _micLevel = value;
        notifyListeners();
      case PlayLevel(:final value):
        _voiceLevel = value;
        notifyListeners();
      case PlayEvent(:final phase):
        if (phase == PlayPhase.done || phase == PlayPhase.stopped || phase == PlayPhase.error) {
          if (_phase == CallPhase.speaking) _set(CallPhase.listening);
        }
      case SpeechStart() || Utterance() || CallError():
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
        if (_bargeIn && _phase == CallPhase.speaking) {
          unawaited(_stopPlay());
          _session?.cancelResponse();
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
          _turnYou = said;
          _live = '';
          notifyListeners();
        }
      case QwenRealtimeResponseStarted(:final responseId):
        _responseId = responseId;
        _reply = '';
        _said = '';
        _error = null;
        unawaited(_beginPlay(responseId));
        _set(CallPhase.speaking);
      case QwenRealtimeOutputDelta(:final text):
        _reply += text;
        _said = _reply;
        notifyListeners();
      case QwenRealtimeOutputFinal(:final text):
        if (text.trim().isNotEmpty) {
          _reply = text.trim();
          _said = _reply;
        }
        _commitTurn();
        notifyListeners();
      case QwenRealtimeAudioDelta(:final pcm, :final responseId):
        unawaited(_writePlay(responseId, pcm));
      case QwenRealtimeResponseDone():
        unawaited(_endPlay());
        if (_phase == CallPhase.speaking) _set(CallPhase.listening);
      case QwenRealtimeCleared():
        unawaited(_stopPlay());
        if (_phase == CallPhase.speaking) _set(CallPhase.listening);
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

  void _commitTurn() {
    final you = _turnYou.trim();
    final her = _reply.trim();
    if (you.isEmpty && her.isEmpty) return;
    if (_turns.isNotEmpty && _turns.last.you == you && her.startsWith(_turns.last.her)) {
      _turns[_turns.length - 1] = CallTurn(you, her: her);
    } else {
      _turns.add(CallTurn(you.isEmpty ? '…' : you, her: her));
    }
    if (her.isNotEmpty) _turnYou = '';
  }

  Future<void> _beginPlay(String responseId) async {
    await _stopPlay();
    final id = 'rt-$responseId';
    _playId = id;
    _responseId = responseId;
    final ok = await audio.open(id, rate: 24000, call: true, levels: true);
    if (!ok) _playId = null;
  }

  Future<void> _writePlay(String responseId, Uint8List pcm) async {
    if (_playId == null || _responseId != responseId) await _beginPlay(responseId);
    final id = _playId;
    if (id == null) return;
    await audio.write(id, pcm);
  }

  Future<void> _endPlay() async {
    final id = _playId;
    if (id == null) return;
    await audio.end(id);
  }

  Future<void> _stopPlay() async {
    final id = _playId;
    _playId = null;
    _responseId = null;
    _voiceLevel = 0;
    if (id != null) await audio.stop();
  }

  @override
  void hangUp() => _end(CallEnd.hungUp);

  @override
  void backgrounded() {
    if (!_asking) _end(CallEnd.background);
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
    if (_phase != CallPhase.speaking) return;
    _session?.cancelResponse();
    unawaited(_stopPlay());
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
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _sessionSub?.cancel();
    _sessionSub = null;
    await pcm.stop();
    await _stopPlay();
    await audio.stopCall();
    await _session?.close();
    _session = null;
  }

  void _set(CallPhase phase) {
    if (_phase == phase || _phase == CallPhase.ended) return;
    realtimeLog('phase $_phase → $phase');
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_phase != CallPhase.ended) _end(CallEnd.hungUp);
    super.dispose();
  }
}
