import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/geometry.dart';
import '../data/models.dart';
import 'media_cache.dart';
import 'stick_rigs.dart';
import 'viewport.dart';

/// A faded copy of a neighbouring frame, used for onion skinning.
class OnionLayer {
  const OnionLayer(this.objects, this.tint, this.alpha);

  final List<SceneObject> objects;
  final Color tint;
  final double alpha;
}

/// Everything the canvas needs to draw one frame. Built by the canvas widget
/// each repaint so the painter itself stays stateless and cheap to compare.
class ScenePainter extends CustomPainter {
  ScenePainter({
    required this.viewport,
    required this.objects,
    required this.backgroundColor,
    this.backgroundImage,
    this.media,
    this.onion = const [],
    this.selectedId,
    this.activeStroke,
    this.frameIndex = 0,
    this.showHandles = true,
    this.showStageBorder = true,
    this.emptyHint = 'Toque + para adicionar um boneco',
  }) : super(repaint: null);

  final Viewport viewport;
  final List<SceneObject> objects;
  final Color backgroundColor;
  final ui.Image? backgroundImage;
  final MediaCache? media;
  final List<OnionLayer> onion;
  final String? selectedId;

  /// Points of a stroke the user is drawing right now, drawn as a live
  /// preview so the pen never feels laggy.
  final List<Vec2>? activeStroke;
  final int activeStrokeColor;
  final double activeStrokeThickness;

  /// Playback position in frames, used to advance animated sprite sheets.
  final int frameIndex;
  final bool showHandles;
  final bool showStageBorder;
  final String emptyHint;

  @override
  void paint(Canvas canvas, Size size) {
    final vp = viewport.copyWith(canvasSize: Size(size.width, size.height));
    final stageRect = Rect.fromLTWH(0, 0, vp.stageSize.x, vp.stageSize.y);

    // Backdrop outside the stage.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF15171C),
    );

    // Stage background, drawn in *view* space so it does not rotate with the
    // camera unless the user asked for that explicitly.
    final o = vp.origin;
    final stagePx = Rect.fromLTWH(
      o.x,
      o.y,
      vp.stageSize.x * vp.scale,
      vp.stageSize.y * vp.scale,
    );

    canvas.save();
    _clipRotatedStage(canvas, vp, stagePx);
    canvas.drawRect(stagePx, Paint()..color = backgroundColor);

    if (backgroundImage != null) {
      _drawImageCover(canvas, backgroundImage!, stagePx);
    }

    canvas.save();
    vp.apply(canvas);

    for (final layer in onion) {
      for (final o2 in layer.objects) {
        _drawObject(
          canvas,
          o2,
          colorOverride: layer.tint,
          alphaMultiplier: layer.alpha,
        );
      }
    }

    for (final obj in objects) {
      _drawObject(canvas, obj);
    }

    final live = activeStroke;
    if (live != null && live.isNotEmpty) {
      _stroke(
        canvas,
        StrokeObject(
          id: '__live__',
          points: live,
          color: activeStrokeColor,
          thickness: activeStrokeThickness,
        ),
        Color(activeStrokeColor).withValues(alpha: 1),
        null,
      );
    }

    canvas.restore(); // vp transform
    canvas.restore(); // stage clip

    if (objects.isEmpty && onion.isEmpty) {
      _drawEmptyHint(canvas, size, stagePx);
    }

    if (showStageBorder) {
      canvas.drawRect(
        stagePx,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0x33FFFFFF),
      );
    }

    if (selectedId != null && showHandles) {
      final sel = _findSelected();
      if (sel != null) _drawSelection(canvas, vp, sel);
    }
  }

  void _clipRotatedStage(Canvas canvas, Viewport vp, Rect stagePx) {
    // Rotating about the stage centre matches how the camera feels.
    if (vp.cameraRotation == 0) {
      canvas.clipRect(stagePx);
      return;
    }
    final center = stagePx.center;
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(-vp.cameraRotation)
      ..translate(-center.dx, -center.dy);
    canvas.clipRect(stagePx);
    canvas.restore();
  }

  void _drawImageCover(Canvas canvas, ui.Image img, Rect dst) {
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    if (iw <= 0 || ih <= 0) return;
    final scale = math.max(dst.width / iw, dst.height / ih);
    final w = iw * scale;
    final h = ih * scale;
    final src = Rect.fromLTWH(0, 0, iw, ih);
    final out = Rect.fromLTWH(
      dst.center.dx - w / 2,
      dst.center.dy - h / 2,
      w,
      h,
    );
    canvas.drawImageRect(
      img,
      src,
      out,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _drawEmptyHint(Canvas canvas, Size size, Rect stagePx) {
    final tp = TextPainter(
      text: TextSpan(
        text: emptyHint,
        style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: stagePx.width - 24);
    tp.paint(
      canvas,
      Offset(stagePx.center.dx - tp.width / 2, stagePx.center.dy),
    );
  }

  SceneObject? _findSelected() {
    for (final o in objects) {
      if (o.id == selectedId) return o;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Object rendering
  // -------------------------------------------------------------------------

  void _drawObject(
    Canvas canvas,
    SceneObject obj, {
    Color? colorOverride,
    double alphaMultiplier = 1,
  }) {
    if (!obj.visible) return;
    final alpha = (obj.opacity * alphaMultiplier).clamp(0.0, 1.0);
    if (alpha <= 0.001) return;

    canvas.save();
    final t = obj.transform;
    canvas
      ..translate(t.translation.x, t.translation.y)
      ..rotate(t.rotation)
      ..scale(t.scale);

    switch (obj) {
      case StrokeObject():
        _stroke(
          canvas,
          obj,
          Color(obj.color).withValues(alpha: alpha),
          alphaMultiplier > 0 && colorOverride != null ? colorOverride : null,
        );
      case CircleObject():
        _circle(canvas, obj, alpha);
      case FillObject():
        _fill(canvas, obj, alpha);
      case FigureObject():
        _figure(canvas, obj, alpha);
      case TextObject():
        _text(canvas, obj, alpha);
      case SpriteObject():
        _sprite(canvas, obj, alpha);
      case MovieclipObject():
        _movieclipPlaceholder(canvas, obj, alpha);
    }

    canvas.restore();
  }

  void _stroke(Canvas canvas, StrokeObject o, Color color, Color? override) {
    if (o.points.length < 2) {
      // A single tap still deserves a dot.
      if (o.points.length == 1) {
        canvas.drawCircle(
          Offset(o.points.first.x, o.points.first.y),
          o.thickness / 2,
          Paint()..color = (override ?? color),
        );
      }
      return;
    }
    final path = Path()..moveTo(o.points.first.x, o.points.first.y);
    for (final p in o.points.skip(1)) {
      path.lineTo(p.x, p.y);
    }
    if (o.closed) path.close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = o.thickness
        ..strokeCap = o.cap == CapStyle.round ? StrokeCap.round : StrokeCap.butt
        ..strokeJoin = StrokeJoin.round
        ..color = override ?? color,
    );
  }

  void _circle(Canvas canvas, CircleObject o, double alpha) {
    final color = Color(o.color).withValues(alpha: alpha);
    if (o.filled) {
      canvas.drawCircle(
        Offset(o.center.x, o.center.y),
        o.radius,
        Paint()..color = color,
      );
    } else {
      canvas.drawCircle(
        Offset(o.center.x, o.center.y),
        o.radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = o.thickness
          ..color = color,
      );
    }
  }

  void _fill(Canvas canvas, FillObject o, double alpha) {
    if (o.points.length < 3) return;
    final path = Path()..moveTo(o.points.first.x, o.points.first.y);
    for (final p in o.points.skip(1)) {
      path.lineTo(p.x, p.y);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = Color(o.color).withValues(alpha: alpha),
    );
  }

  /// Draws a figure as a circle for the head plus one stroke per bone.
  ///
  /// Head radius scales with stroke thickness so the whole figure keeps its
  /// proportions when the user makes it thicker or thinner.
  void _figure(Canvas canvas, FigureObject f, double alpha) {
    final color = Color(f.color).withValues(alpha: alpha);

    for (final bone in f.bones) {
      if (bone.thickness <= 0) continue;
      canvas.drawLine(
        Offset(bone.a.x, bone.a.y),
        Offset(bone.b.x, bone.b.y),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = bone.thickness
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }

    final headAnchor = f.anchors[Anchor.head];
    if (headAnchor != null) {
      final r = f.thickness * 1.5;
      canvas.drawCircle(
        Offset(headAnchor.x, headAnchor.y - r * 0.55),
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = f.thickness
          ..color = color,
      );
    }

    if (f.showJoints) {
      for (final j in f.joints) {
        canvas.drawCircle(
          Offset(j.p.x, j.p.y),
          j.radius,
          Paint()..color = Color(j.color).withValues(alpha: alpha),
        );
      }
      for (final a in f.anchors.entries) {
        canvas.drawCircle(
          Offset(a.value.x, a.value.y),
          3.0,
          Paint()..color = const Color(0xFF3B82F6).withValues(alpha: alpha),
        );
      }
    }
  }

  void _text(Canvas canvas, TextObject o, double alpha) {
    final color = Color(o.color).withValues(alpha: alpha);

    if (o.bubble != BubbleStyle.none) {
      final bubblePath = _bubblePath(o, Offset.zero, _measure(o));
      if (o.backgroundColor != null) {
        canvas.drawPath(
          bubblePath,
          Paint()..color = Color(o.backgroundColor!).withValues(alpha: alpha),
        );
        canvas.drawPath(
          bubblePath,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Color(o.outlineColor).withValues(alpha: alpha * 0.9),
        );
      }
    }

    final size = _measure(o);
    final tp = TextPainter(
      text: TextSpan(
        text: o.text,
        style: TextStyle(
          color: color,
          fontSize: o.fontSize,
          height: 1.25,
          fontWeight: FontWeight.w600,
        ),
      ),
      textAlign: switch (o.align) {
        TextAlign.left => TextAlign.left,
        TextAlign.center => TextAlign.center,
        TextAlign.right => TextAlign.right,
      },
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(size.width - o.padding * 2, 24));

    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  }

  Size _measure(TextObject o) {
    final lines = o.text.split('\n');
    final longest = lines.isEmpty
        ? 0
        : lines.map((l) => l.length).reduce(math.max);
    final w = longest * o.fontSize * 0.58 + o.padding * 2;
    final h = lines.length * o.fontSize * 1.25 + o.padding * 2;
    return Size(math.max(w, 24), math.max(h, 24));
  }

  Path _bubblePath(TextObject o, Offset at, Size size) {
    final r = math.min(14.0, size.height / 2);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            at.dx - size.width / 2,
            at.dy - size.height / 2,
            size.width,
            size.height,
          ),
          Radius.circular(r),
        ),
      );
    if (o.bubble == BubbleStyle.tailLeft || o.bubble == BubbleStyle.tailRight) {
      final dir = o.bubble == BubbleStyle.tailLeft ? -1.0 : 1.0;
      final baseX = at.dx + dir * size.width * 0.25;
      final bottom = at.dy + size.height / 2;
      path
        ..lineTo(baseX - 12 * dir, bottom)
        ..lineTo(baseX + 6 * dir, bottom + 22)
        ..close();
    }
    return path;
  }

  void _sprite(Canvas canvas, SpriteObject o, double alpha) {
    final img = media?.peek(o.assetPath);
    if (img == null) {
      // Placeholder while the image loads, or if the file went missing. A
      // visible placeholder is better than an invisible object the user cannot
      // select and delete.
      final w = o.naturalWidth;
      final h = o.naturalHeight;
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0x88FF5252),
      );
      return;
    }

    final cols = math.max(1, o.spriteColumns);
    final rows = math.max(1, o.spriteRows);
    final cellW = img.width / cols;
    final cellH = img.height / rows;

    final frame = o.spriteFrames <= 1
        ? 0
        : (frameIndex % o.spriteFrames).clamp(0, o.spriteFrames - 1);
    final col = frame % cols;
    final row = frame ~/ cols;

    final src = Rect.fromLTWH(col * cellW, row * cellH, cellW, cellH);
    final dst = Rect.fromCenter(
      center: Offset.zero,
      width: o.naturalWidth,
      height: o.naturalHeight,
    );

    canvas.drawImageRect(
      img,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(alpha: alpha),
    );
  }

  /// Only reached when a clip could not be expanded (missing, empty, or nested
  /// past the depth limit). Makes the problem visible instead of silent.
  void _movieclipPlaceholder(Canvas canvas, MovieclipObject o, double alpha) {
    final r = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-40, -24, 80, 48),
      const Radius.circular(6),
    );
    canvas.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Color(0xFF8B5CF6).withValues(alpha: alpha),
    );
    final tp = TextPainter(
      text: const TextSpan(
        text: 'clip',
        style: TextStyle(color: Color(0xFF8B5CF6), fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  }

  // -------------------------------------------------------------------------
  // Selection
  // -------------------------------------------------------------------------

  void _drawSelection(Canvas canvas, Viewport vp, SceneObject o) {
    final bounds = o.localBounds.transformedBy(o.transform);
    if (bounds.isEmpty) return;

    canvas.save();
    vp.apply(canvas);
    final rect = Rect.fromLTRB(
      bounds.left,
      bounds.top,
      bounds.right,
      bounds.bottom,
    );

    // Constant on-screen thickness regardless of zoom.
    final stroke = 1.5 / vp.scale;

    canvas.drawRect(
      rect.inflate(4 / vp.scale),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = const Color(0xFF3B82F6),
    );

    if (o is FigureObject) {
      for (final a in o.anchors.entries) {
        final p = a.value;
        canvas.drawCircle(
          Offset(p.x, p.y),
          5 / vp.scale,
          Paint()..color = const Color(0xFFFFFFFF),
        );
        canvas.drawCircle(
          Offset(p.x, p.y),
          5 / vp.scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..color = const Color(0xFF3B82F6),
        );
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(ScenePainter old) =>
      old.objects != objects ||
      old.onion != onion ||
      old.viewport.scale != viewport.scale ||
      old.viewport.userPan != viewport.userPan ||
      old.backgroundColor != backgroundColor ||
      old.backgroundImage != backgroundImage ||
      old.selectedId != selectedId ||
      old.media != media;
}
