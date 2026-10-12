import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'exporter.dart';

/// One sound placed on the export timeline.
class AudioPlacement {
  const AudioPlacement({
    required this.path,
    required this.startMs,
    this.volume = 1.0,
    this.durationMs = 0,
  });

  final String path;
  final int startMs;
  final double volume;
  final int durationMs;

  Map<String, Object?> toMap() => {
    'path': path,
    'startMs': startMs,
    'volume': volume,
    'durationMs': durationMs,
  };
}

class VideoExportOutcome {
  const VideoExportOutcome({
    required this.path,
    required this.frames,
    required this.durationMs,
    required this.hasAudio,
  });

  final String path;
  final int frames;
  final int durationMs;
  final bool hasAudio;
}

/// True when the running platform has the native encoder.
bool get isVideoExportSupported {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android &&
      (Platform.isAndroid);
}

/// Drives the native MP4 encoder.
///
/// The renderer and the native side split the work like this: Dart paints each
/// frame and ships it as PNG, the encoder draws it into the MediaCodec input
/// Surface. PNG costs a little CPU but keeps the pixel format conversion on
/// Android's side, where it is already fast and well tested.
class VideoExporter {
  VideoExporter({
    this.channelName = 'stickscene/video',
    this.stageWidth = 480,
    this.stageHeight = 640,
  });

  final String channelName;
  final double stageWidth;
  final double stageHeight;
  MethodChannel? _channel;

  MethodChannel get _ch => _channel ??= MethodChannel(channelName);

  Future<VideoExportOutcome> export({
    required Sequence sequence,
    required SequenceExporter renderer,
    required String outputPath,
    required double scale,
    int? targetFps,
    void Function(double fraction, int frame, int total)? onProgress,
  }) async {
    if (!isVideoExportSupported) {
      throw UnsupportedError(
        'MP4 export needs Android. GIF and PNG exports work everywhere.',
      );
    }

    final fps = targetFps ?? sequence.fps.clamp(1, 60);
    final width = (stageWidth * scale).round();
    final height = (stageHeight * scale).round();
    // H.264 requires even dimensions; a 481px wide frame would be rejected.
    final outW = width - (width % 2);
    final outH = height - (height % 2);
    if (outW < 2 || outH < 2) {
      throw ArgumentError('export size collapsed to ${outW}x$outH');
    }

    final placements = buildAudioPlacements(sequence, fps);
    final totalMs =
        (sequence.frames.isEmpty ? 0 : 1000 / fps * frameSlots(sequence))
            .round();

    await _ch.invokeMethod<void>('startExport', {
      'path': outputPath,
      'width': outW,
      'height': outH,
      'fps': fps,
      'durationMs': totalMs,
      'bitrate': suggestedBitrate(outW, outH, fps),
      'audioTracks': placements.map((p) => p.toMap()).toList(),
    });

    final positions = _positions(sequence, fps);
    try {
      for (var i = 0; i < positions.length; i++) {
        final rgba = await renderer.renderFrameRgba(
          sequence,
          positions[i],
          outW,
          outH,
        );
        final png = await _encodePng(rgba.image, rgba.bytes);
        await _ch.invokeMethod<void>('addFrame', {'png': png, 'index': i});
        rgba.image.dispose();
        onProgress?.call((i + 1) / positions.length, i + 1, positions.length);
      }
    } catch (_) {
      await _ch.invokeMethod<void>('cancelExport', null);
      rethrow;
    }

    final result = await _ch.invokeMapMethod<String, Object?>('finishExport');
    if (result == null) {
      throw StateError('the native encoder returned no result');
    }
    final hasAudio = result['hasAudio'] == true;
    return VideoExportOutcome(
      path: (result['path'] as String?) ?? outputPath,
      frames: (result['frames'] as num?)?.toInt() ?? positions.length,
      durationMs: (result['durationMs'] as num?)?.toInt() ?? totalMs,
      hasAudio: hasAudio && placements.isNotEmpty,
    );
  }

  Future<void> cancel() async {
    if (!isVideoExportSupported) return;
    try {
      await _ch.invokeMethod<void>('cancelExport', null);
    } catch (_) {
      // Cancelling is best effort; never let it mask the original failure.
    }
  }

  /// Rough bitrate: ~0.08 bits per pixel per frame keeps line art crisp without
  /// producing a file the size of a movie.
  static int suggestedBitrate(int w, int h, int fps) =>
      (w * h * fps * 0.12).round().clamp(800000, 16000000);

  /// Total timeline slots, honouring per-frame holds.
  static int frameSlots(Sequence sequence) {
    var total = 0;
    for (final f in sequence.frames) {
      total += f.hold < 1 ? 1 : f.hold;
    }
    return total;
  }

  /// Flattens the sequence's audio into absolute positions on the timeline.
  static List<AudioPlacement> buildAudioPlacements(Sequence sequence, int fps) {
    final out = <AudioPlacement>[];
    var slotCursor = 0;

    for (var i = 0; i < sequence.frames.length; i++) {
      final frame = sequence.frames[i];
      final hold = frame.hold < 1 ? 1 : frame.hold;
      final frameStartMs = ((slotCursor / fps) * 1000).round();

      for (final cue in frame.audio) {
        if (cue.spriteFrames > 0) continue; // animated images are not sound
        final file = File(cue.assetPath);
        if (!file.existsSync()) continue;
        out.add(
          AudioPlacement(
            path: cue.assetPath,
            startMs: frameStartMs + (cue.startFrame / fps * 1000).round(),
            volume: cue.volume.clamp(0.0, 1.0),
            durationMs: (cue.durationSeconds * 1000).round(),
          ),
        );
      }
      slotCursor += hold;
    }

    final music = sequence.music;
    if (music != null && music.enabled && File(music.assetPath).existsSync()) {
      out.insert(
        0,
        AudioPlacement(
          path: music.assetPath,
          startMs: 0,
          volume: music.volume.clamp(0.0, 1.0),
        ),
      );
    }
    return out;
  }

  List<double> _positions(Sequence sequence, int fps) {
    final slots = <int>[];
    for (var i = 0; i < sequence.frames.length; i++) {
      final hold = sequence.frames[i].hold < 1 ? 1 : sequence.frames[i].hold;
      for (var h = 0; h < hold; h++) {
        slots.add(i);
      }
    }
    if (slots.isEmpty) return const [];

    final total = slots.length;
    final sourceFps = sequence.fps <= 0 ? 12 : sequence.fps;
    final count = ((total / sourceFps) * fps).round().clamp(1, 4000);

    final out = <double>[];
    for (var k = 0; k < count; k++) {
      final slotPos = k * total / count;
      final idx = slotPos.floor().clamp(0, total - 1);
      final frac = slotPos - idx;
      final frameIndex = slots[idx];
      // Only blend into the next pose once we are past the midpoint of this
      // slot, otherwise a held frame would drift into its neighbour.
      final blendable =
          idx + 1 < total && slots[idx + 1] != frameIndex && frac > 0.5;
      out.add(blendable ? frameIndex + (frac - 0.5) : frameIndex.toDouble());
    }
    return out;
  }

  Future<Uint8List> _encodePng(ui.Image image, Uint8List raw) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}

/// Result bundle from one rendered frame: the image plus its raw RGBA pixels.
typedef RenderedFrame = ({ui.Image image, Uint8List bytes});
