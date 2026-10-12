import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/geometry.dart';
import '../data/models.dart';
import '../editor/canvas_painter.dart';
import '../editor/editor_controller.dart';
import '../editor/interpolation.dart';
import '../editor/media_cache.dart';
import '../editor/viewport.dart';
import 'gif_encoder.dart';

enum ExportFormat { gif, spriteSheet, pngSequence }

class ExportProgress {
  const ExportProgress(this.done, this.total, this.currentLabel);

  final int done;
  final int total;
  final String currentLabel;

  double get fraction => total <= 0 ? 0 : done / total;
}

class ExportResult {
  const ExportResult(this.path, this.frames, this.bytesWritten, this.note);

  final String path;
  final int frames;
  final int bytesWritten;

  /// Set when the export is incomplete for a reason the user should know about,
  /// e.g. GIF being silent while the project has audio.
  final String? note;
}

/// Renders a sequence to image files.
///
/// Every output goes through the same [ScenePainter] the editor uses, so the
/// exported file matches the preview by construction rather than by luck.
class SequenceExporter {
  SequenceExporter({required this.controller, this.mediaCache});

  final EditorController controller;
  final MediaCache? mediaCache;

  /// Fraction of the preview resolution to export. 1.0 means "exactly what you
  /// see on screen", which is almost never what you want for a GIF - most
  /// phones cannot play a 1080p GIF.
  double scale = 0.5;

  Future<ExportResult> export({
    required ExportFormat format,
    required Directory outputDir,
    ExportFormat? target,
    int? overrideFps,
  }) async {
    final sequence = controller.sequence;
    if (sequence.frames.isEmpty) {
      throw StateError('nothing to export: the sequence has no frames');
    }
    if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

    final fmt = target ?? format;
    final positions = _framePositions(sequence, overrideFps ?? sequence.fps);
    final outW = (controller.project.stageWidth * scale).round();
    final outH = (controller.project.stageHeight * scale).round();
    if (outW <= 0 || outH <= 0) {
      throw StateError('export size collapsed to ${outW}x$outH');
    }

    final safeName = _safe(controller.project.name);
    String? note;

    if (fmt == ExportFormat.gif) {
      final gif = await _renderGif(sequence, positions, outW, outH);
      final file = File('${outputDir.path}/$safeName.gif');
      await file.writeAsBytes(gif, flush: true);
      if (_hasAudio(sequence)) {
        note = 'GIF não tem áudio. Os sons ficaram só no projeto.';
      }
      return ExportResult(file.path, positions.length, gif.length, note);
    }

    if (fmt == ExportFormat.spriteSheet) {
      final images = await _renderAll(sequence, positions, outW, outH);
      final columns = _bestGridColumns(images.length);
      final rows = (images.length / columns).ceil();
      final sheet = await _composeSheet(images, columns, rows, outW, outH);
      final bytes = await _encodePng(sheet);
      final file = File('${outputDir.path}/${safeName}_spritesheet.png');
      await file.writeAsBytes(bytes, flush: true);
      return ExportResult(
        file.path,
        images.length,
        bytes.length,
        'Grade ${columns}x$rows',
      );
    }

    // PNG sequence
    var totalBytes = 0;
    for (var i = 0; i < positions.length; i++) {
      final img = await _renderOne(sequence, positions[i], outW, outH);
      final bytes = await _encodePng(img);
      final file = File(
        '${outputDir.path}/$safeName${i.toString().padLeft(4, '0')}.png',
      );
      await file.writeAsBytes(bytes, flush: true);
      totalBytes += bytes.length;
      img.dispose();
      await Future<void>.delayed(Duration.zero);
    }
    return ExportResult(outputDir.path, positions.length, totalBytes, null);
  }

  bool _hasAudio(Sequence s) {
    if (s.music != null && s.music!.enabled) return true;
    for (final f in s.frames) {
      if (f.audio.isNotEmpty) return true;
    }
    return false;
  }

  /// Fractional frame positions to render.
  ///
  /// When the target fps differs from the sequence fps the renderer walks slot
  /// positions, which is what makes smooth 24fps output from a 12fps
  /// hand-animated sequence (the in-between frames come from the interpolator).
  List<double> _framePositions(Sequence sequence, int targetFps) {
    final slots = <int>[];
    for (var i = 0; i < sequence.frames.length; i++) {
      final hold = sequence.frames[i].hold < 1 ? 1 : sequence.frames[i].hold;
      for (var h = 0; h < hold; h++) {
        slots.add(i);
      }
    }
    if (slots.isEmpty) return const [];

    final totalSlots = slots.length;
    final sourceFps = sequence.fps <= 0 ? 12 : sequence.fps;
    final outputCount =
        ((totalSlots / sourceFps) * (targetFps <= 0 ? sourceFps : targetFps))
            .round()
            .clamp(1, 4000);

    final out = <double>[];
    for (var k = 0; k < outputCount; k++) {
      final slotPos = k * totalSlots / outputCount;
      final slotIndex = slotPos.floor().clamp(0, totalSlots - 1);
      final frac = slotPos - slotIndex;
      final frameIndex = slots[slotIndex];
      // Blend towards the next real frame within the same run of the same
      // index, otherwise a held frame would drift into the next pose.
      final nextInRun =
          slotIndex + 1 < totalSlots &&
          slots[slotIndex + 1] != frameIndex &&
          (slotPos - slotIndex) > 0.5;
      out.add(nextInRun ? frameIndex + frac * 0.999 : frameIndex.toDouble());
    }
    return out;
  }

  Future<Uint8List> _renderGif(
    Sequence sequence,
    List<double> positions,
    int w,
    int h,
  ) async {
    final encoder = GifEncoder(loop: sequence.loop ? 0 : -1);
    final delayMs =
        ((positions.length / (sequence.fps <= 0 ? 12 : sequence.fps)) * 1000) /
        positions.length;
    encoder.frameDelayMs = delayMs.round().clamp(20, 5000);

    for (var i = 0; i < positions.length; i++) {
      final rgba = await _renderRgba(sequence, positions[i], w, h);
      encoder.addFrame(rgba, w, h);
      // Yield so the progress UI stays responsive on a long sequence.
      await Future<void>.delayed(Duration.zero);
    }
    return encoder.finish();
  }

  Future<List<ui.Image>> _renderAll(
    Sequence sequence,
    List<double> positions,
    int w,
    int h,
  ) async {
    final out = <ui.Image>[];
    for (final p in positions) {
      out.add(await _renderOne(sequence, p, w, h));
      await Future<void>.delayed(Duration.zero);
    }
    return out;
  }

  /// Renders one frame and returns both the image and its unpremultiplied RGBA
  /// pixels. Shared with the MP4 pipeline, which needs the raw pixels to hand
  /// to the platform channel.
  Future<RenderedFrame> renderFrameRgba(
    Sequence sequence,
    double position,
    int w,
    int h,
  ) async => _renderRgbaWithImage(sequence, position, w, h);

  /// Draws one frame through the exact same painter the editor canvas uses.
  Future<ui.Image> _renderOne(
    Sequence sequence,
    double position,
    int w,
    int h,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    );

    final scene = resolveScene(sequence, position);
    final objects = controller.visibleObjects(scene);

    final viewport = StageViewport(
      canvasSize: Size(w.toDouble(), h.toDouble()),
      stageSize: Vec2(
        controller.project.stageWidth,
        controller.project.stageHeight,
      ),
      padding: 0,
      userZoom: scale,
      cameraCenter: scene.camera.center,
      cameraZoom: scene.camera.zoom,
      cameraRotation: scene.camera.rotation,
    );

    ScenePainter(
      viewport: viewport,
      objects: objects,
      backgroundColor: Color(sequence.background.color),
      media: mediaCache,
      frameIndex: position.round(),
      showHandles: false,
      showStageBorder: false,
    ).paint(canvas, Size(w.toDouble(), h.toDouble()));

    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    return image;
  }

  /// Renders one frame straight to unpremultiplied RGBA, which is what the
  /// quantiser and the LZW encoder both want. Going through PNG here would
  /// cost an encode/decode round trip for nothing.
  Future<Uint8List> _renderRgba(
    Sequence sequence,
    double position,
    int w,
    int h,
  ) async {
    final frame = await _renderRgbaWithImage(sequence, position, w, h);
    frame.image.dispose();
    return frame.bytes;
  }

  /// Renders a frame and returns it together with its unpremultiplied RGBA copy.
  Future<RenderedFrame> _renderRgbaWithImage(
    Sequence sequence,
    double position,
    int w,
    int h,
  ) async {
    final image = await _renderOne(sequence, position, w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final src = data!.buffer.asUint8List();
    final out = Uint8List(src.length);
    for (var i = 0; i < src.length; i += 4) {
      final a = src[i + 3];
      if (a == 255) {
        out[i] = src[i];
        out[i + 1] = src[i + 1];
        out[i + 2] = src[i + 2];
      } else if (a == 0) {
        out[i] = 0;
        out[i + 1] = 0;
        out[i + 2] = 0;
      } else {
        // Flutter hands back premultiplied RGBA; undo that so the quantiser
        // sees the colour the user actually painted.
        out[i] = (src[i] * 255 / a).round().clamp(0, 255);
        out[i + 1] = (src[i + 1] * 255 / a).round().clamp(0, 255);
        out[i + 2] = (src[i + 2] * 255 / a).round().clamp(0, 255);
      }
      out[i + 3] = a;
    }
    return (image: image, bytes: out);
  }

  Future<Uint8List> _encodePng(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<ui.Image> _composeSheet(
    List<ui.Image> images,
    int columns,
    int rows,
    int w,
    int h,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final tileW = w * columns;
    final tileH = h * rows;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, tileW.toDouble(), tileH.toDouble()),
      Paint()..color = const Color(0x00000000),
    );
    for (var i = 0; i < images.length; i++) {
      final col = i % columns;
      final row = i ~/ columns;
      canvas.drawImageRect(
        images[i],
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Rect.fromLTWH(
          (col * w).toDouble(),
          (row * h).toDouble(),
          w.toDouble(),
          h.toDouble(),
        ),
        Paint()..filterQuality = ui.FilterQuality.none,
      );
    }
    final picture = recorder.endRecording();
    final sheet = await picture.toImage(tileW, tileH);
    picture.dispose();
    for (final img in images) {
      img.dispose();
    }
    return sheet;
  }

  int _bestGridColumns(int count) {
    if (count <= 1) return 1;
    // Aim for a roughly square sheet; 16 is a sane cap for huge animations.
    var best = 1;
    var bestScore = double.infinity;
    for (var c = 1; c <= 16 && c <= count; c++) {
      final rows = (count / c).ceil();
      final score = (c - rows).abs().toDouble();
      if (score < bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  static String _safe(String name) {
    final s = name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(' ', '_');
    return s.isEmpty ? 'animacao' : s;
  }
}

/// A frame rendered for export: the image plus a straight-RGBA pixel copy.
typedef RenderedFrame = ({ui.Image image, Uint8List bytes});

/// Tracks an export so the UI can show progress and offer a cancel.
class ExportJob {
  ExportJob(this.exporter, this.format, this.outputDir);

  final SequenceExporter exporter;
  final ExportFormat format;
  final Directory outputDir;

  bool cancelled = false;
  final ValueNotifier<ExportProgress?> progress = ValueNotifier(null);

  Future<ExportResult?> run() async {
    try {
      return await exporter.export(format: format, outputDir: outputDir);
    } finally {
      progress.value = null;
    }
  }
}
