import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../data/geometry.dart';
import '../data/models.dart';

/// Drives playback of a [Sequence]: advances frames, interpolates between them
/// and fires the audio cues attached to each frame.
///
/// The exporter uses the same timing maths (`advanceFramesFor`) so a clip looks
/// on screen exactly as it does in the encoded file.
class SequencePlayer extends ChangeNotifier {
  SequencePlayer();

  Sequence? _sequence;
  double _position = 0;
  bool _playing = false;

  /// Currently loaded media handles, keyed by the cue's asset path.
  final Map<String, AudioPlayer> _cuePlayers = {};
  AudioPlayer? _musicPlayer;

  /// Set when the sequence's music track changes so it can be restarted.
  String? _musicPath;

  Sequence? get sequence => _sequence;
  double get position => _position;
  bool get isPlaying => _playing;

  /// True when the sequence has music that should play alongside.
  AudioTrack? get music => _sequence?.music;

  void load(Sequence sequence, {double position = 0}) {
    if (_sequence?.id != sequence.id) {
      _stopAllCues();
      _musicPath = null;
    }
    _sequence = sequence;
    _position = position.clamp(0.0, maxPosition);
    notifyListeners();
  }

  double get maxPosition {
    final s = _sequence;
    if (s == null || s.frames.isEmpty) return 0;
    return (s.frames.length - 1).toDouble();
  }

  void play() {
    final s = _sequence;
    if (s == null || s.frames.isEmpty) return;
    if (_position >= maxPosition && !s.loop) {
      _position = 0;
    }
    _playing = true;
    notifyListeners();
  }

  void pause() {
    _playing = false;
    notifyListeners();
  }

  void toggle() => _playing ? pause() : play();

  void stop() {
    _playing = false;
    _position = 0;
    _stopAllCues();
    notifyListeners();
  }

  void seek(double framePosition) {
    _position = framePosition.clamp(0.0, maxPosition);
    _stopAllCues();
    notifyListeners();
  }

  /// Called from a ticker. [dt] is seconds since the previous call.
  void update(double dt) {
    final s = _sequence;
    if (!_playing || s == null || s.frames.isEmpty) return;

    final fps = s.fps <= 0 ? 12 : s.fps;
    final before = _position;
    var next = _position + dt * fps;

    if (next > maxPosition) {
      if (s.loop) {
        // Wrap around and fire the cues of the frame we land on.
        next = next % maxPosition;
      } else {
        next = maxPosition;
        _playing = false;
      }
    }

    _position = next;

    // Fire cues for every frame boundary we crossed, so short frames do not
    // silently swallow their sound.
    final crossed = <int>{};
    var probe = before.floor() + 1;
    while (probe <= next.floor() && probe <= maxPosition) {
      crossed.add(probe);
      probe++;
    }
    if (crossed.isEmpty && (next.floor() != before.floor())) {
      crossed.add(next.floor());
    }
    for (final idx in crossed) {
      _fireCuesForFrame(s.frames[idx], idx);
    }

    _ensureMusic();
    notifyListeners();
  }

  void _fireCuesForFrame(Frame frame, int frameIndex) {
    for (final cue in frame.audio) {
      if (cue.startFrame > 0) continue; // handled by the offset branch below
      _playCue(cue, frameIndex);
    }
    // Cues with a positive offset belong to the frame *before* them.
    if (frameIndex > 0) {
      final prev = _sequence!.frames[frameIndex - 1];
      for (final cue in prev.audio) {
        if (cue.startFrame <= 0) continue;
        if (cue.startFrame == frameIndex) _playCue(cue, frameIndex);
      }
    }
  }

  Future<void> _playCue(AudioCue cue, int frameIndex) async {
    if (cue.spriteFrames > 0) return; // animated images are visual, not audio
    final file = File(cue.assetPath);
    if (!file.existsSync()) return;

    var player = _cuePlayers[cue.assetPath];
    if (player == null) {
      player = AudioPlayer(playerId: 'cue-${_cuePlayers.length}')
        ..setReleaseMode(ReleaseMode.stop);
      _cuePlayers[cue.assetPath] = player!;
    }
    try {
      await player!.stop();
      await player.play(
        DeviceFileSource(cue.assetPath),
        volume: cue.volume.clamp(0.0, 1.0),
      );
    } catch (_) {
      // A single failed sound must never stop the animation.
    }
  }

  Future<void> _ensureMusic() async {
    final s = _sequence;
    final track = s?.music;
    if (track == null || !track.enabled) {
      if (_musicPlayer != null) {
        await _musicPlayer?.stop();
        _musicPath = null;
      }
      return;
    }
    if (_musicPath == track.assetPath) return;
    final file = File(track.assetPath);
    if (!file.existsSync()) return;
    _musicPath = track.assetPath;
    try {
      _musicPlayer ??= AudioPlayer(playerId: 'music');
      await _musicPlayer!.setReleaseMode(
        track.loop ? ReleaseMode.loop : ReleaseMode.stop,
      );
      await _musicPlayer!.setVolume(track.volume.clamp(0.0, 1.0));
      await _musicPlayer!.play(DeviceFileSource(track.assetPath));
    } catch (_) {
      _musicPath = null;
    }
  }

  void _stopAllCues() {
    for (final p in _cuePlayers.values) {
      p.stop();
    }
  }

  /// Preview a single sound from the editor's audio list.
  Future<void> previewCue(AudioCue cue) async {
    final file = File(cue.assetPath);
    if (!file.existsSync()) return;
    try {
      final p = AudioPlayer(playerId: 'preview')
        ..setReleaseMode(ReleaseMode.stop);
      await p.setVolume(cue.volume.clamp(0.0, 1.0));
      await p.play(DeviceFileSource(cue.assetPath));
    } catch (_) {}
  }

  @override
  void dispose() {
    _stopAllCues();
    _musicPlayer?.dispose();
    for (final p in _cuePlayers.values) {
      p.dispose();
    }
    super.dispose();
  }

  /// Total wall-clock length of the sequence, honouring per-frame holds.
  Duration durationOf(Sequence sequence) {
    if (sequence.frames.isEmpty) return Duration.zero;
    final fps = sequence.fps <= 0 ? 12 : sequence.fps;
    var totalSlots = 0;
    for (final f in sequence.frames) {
      totalSlots += f.hold < 1 ? 1 : f.hold;
    }
    return Duration(milliseconds: (totalSlots * 1000 / fps).round());
  }

  /// How many frames to render per second when exporting at [targetFps].
  ///
  /// A frame with hold=3 shown at 12fps must occupy 3 slots, so the exporter
  /// walks slot indices rather than frame indices.
  static List<int> timelineSlots(Sequence sequence) {
    final slots = <int>[];
    for (var i = 0; i < sequence.frames.length; i++) {
      final hold = sequence.frames[i].hold < 1 ? 1 : sequence.frames[i].hold;
      for (var h = 0; h < hold; h++) {
        slots.add(i);
      }
    }
    return slots;
  }
}

/// A lightweight on-screen frame cursor. Kept separate from the player so the
/// timeline can animate independently of playback.
class PlayheadState extends ChangeNotifier {
  double position = 0;
  bool playing = false;

  void update(double value, bool isPlaying) {
    if (position == value && playing == isPlaying) return;
    position = value;
    playing = isPlaying;
    notifyListeners();
  }
}

/// Converts a scene-space point into the frame-local space of a movieclip.
Vec2 applyInverse(Vec2 point, Transform2D t) {
  var q = point - t.translation;
  if (t.scale != 0) q = q / t.scale;
  return q.rotated(-t.rotation);
}
