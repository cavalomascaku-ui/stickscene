import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Loads and caches imported media (sprites, backgrounds) as [ui.Image].
///
/// Animated GIFs are decoded frame-by-frame by the `image` package at export
/// time; for the on-screen preview we only need the first frame, which keeps
/// memory flat no matter how many GIFs a project has.
class MediaCache {
  MediaCache();

  final Map<String, ui.Image> _images = {};
  final Map<String, Future<ui.Image?>> _pending = {};
  final Map<String, List<AnimatedFrame>> _animations = {};

  /// Bytes we are willing to decode for a preview. Anything bigger is decoded
  /// at a reduced size instead, otherwise a 12MP background on a phone will
  /// take the whole heap.
  static const int maxPreviewPixels = 2048 * 2048;

  ui.Image? peek(String path) => _images[path];

  Future<ui.Image?> load(String absolutePath) {
    final existing = _images[absolutePath];
    if (existing != null) return Future.value(existing);
    final inflight = _pending[absolutePath];
    if (inflight != null) return inflight;

    final future = _doLoad(absolutePath);
    _pending[absolutePath] = future;
    return future;
  }

  Future<ui.Image?> _doLoad(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _targetWidth(bytes),
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      _images[path] = image;
      _pending.remove(path);
      return image;
    } catch (_) {
      _pending.remove(path);
      return null;
    }
  }

  int? _targetWidth(Uint8List bytes) {
    // Only bother downscaling if the file is chunky; decoding is synchronous
    // enough that guessing wrong costs more than it saves.
    if (bytes.length < 600 * 1024) return null;
    return 1024;
  }

  /// Decodes an animated GIF/APNG into frames.
  ///
  /// Flutter's own codec walks animated formats if you keep pulling
  /// `getNextFrame()`, which saves pulling in a second image decoder.
  Future<List<AnimatedFrame>> decodeAnimation(String absolutePath) async {
    final cached = _animations[absolutePath];
    if (cached != null) return cached;

    final frames = <AnimatedFrame>[];
    try {
      final bytes = await File(absolutePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        // A hard cap protects against pathological files with tens of
        // thousands of tiny frames.
        while (frames.length < 600) {
          final f = await codec.getNextFrame();
          if (frames.isNotEmpty) frames[frames.length - 1].image.dispose();
          frames.add(
            AnimatedFrame(
              image: f.image,
              duration: f.duration == Duration.zero
                  ? const Duration(milliseconds: 100)
                  : f.duration,
            ),
          );
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return const [];
    }

    _animations[absolutePath] = frames;
    return frames;
  }

  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _pending.clear();
    for (final anim in _animations.values) {
      for (final f in anim) {
        f.image.dispose();
      }
    }
    _animations.clear();
  }

  void dispose() => clear();
}

/// One frame of an animated image plus how long it should be shown.
class AnimatedFrame {
  AnimatedFrame({required this.image, required this.duration});

  ui.Image image;
  Duration duration;

  /// Duration as a float in frames, for GIF encoding.
  double get durationMs => duration.inMicroseconds / 1000.0;
}
