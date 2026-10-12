import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../data/geometry.dart';

/// Maps between scene coordinates and widget pixels.
///
/// Three things stack on top of each other, and keeping them separate is what
/// lets the v-cam animation stay out of the way of the user's own navigation:
///  1. [StageViewport.userPan] / [StageViewport.userZoom] - how the user is looking around
///  2. [CameraKey.zoom] / rotation / centre - the animated camera being previewed
///  3. the "fit the stage into the widget" scale
class StageViewport {
  StageViewport({
    required this.canvasSize,
    required this.stageSize,
    this.userPan = Vec2.zero,
    this.userZoom = 1.0,
    this.cameraCenter = Vec2.zero,
    this.cameraZoom = 1.0,
    this.cameraRotation = 0,
    this.padding = 24,
  });

  Size canvasSize;
  Vec2 stageSize;
  Vec2 userPan;
  double userZoom;
  Vec2 cameraCenter;
  double cameraZoom;
  double cameraRotation;
  double padding;

  /// Scale that makes the stage fit the widget with a margin.
  double get fitScale {
    final w = canvasSize.width - padding * 2;
    final h = canvasSize.height - padding * 2;
    if (w <= 0 || h <= 0) return 1;
    final sx = w / stageSize.x;
    final sy = h / stageSize.y;
    return math.min(sx, sy);
  }

  /// Total pixels-per-scene-unit.
  double get scale => fitScale * userZoom * cameraZoom;

  /// Pixel position of the stage's top-left corner.
  Vec2 get origin {
    final w = stageSize.x * scale;
    final h = stageSize.y * scale;
    return Vec2(
      (canvasSize.width - w) / 2 + userPan.x,
      (canvasSize.height - h) / 2 + userPan.y,
    );
  }

  Vec2 sceneToView(Vec2 p) {
    final q = (p - cameraCenter).rotated(-cameraRotation) * scale;
    return origin + q;
  }

  Vec2 viewToScene(Vec2 pixel) {
    final q = pixel - origin;
    return cameraCenter + (q / scale).rotated(cameraRotation);
  }

  /// Pushes this transform onto a [Canvas] so painting can happen in scene
  /// coordinates.
  void apply(Canvas canvas) {
    final o = origin;
    canvas
      ..translate(o.x, o.y)
      ..rotate(-cameraRotation)
      ..scale(scale)
      ..translate(-cameraCenter.x, -cameraCenter.y);
  }

  StageViewport copyWith({
    Size? canvasSize,
    Vec2? stageSize,
    Vec2? userPan,
    double? userZoom,
    Vec2? cameraCenter,
    double? cameraZoom,
    double? cameraRotation,
    double? padding,
  }) => StageViewport(
    canvasSize: canvasSize ?? this.canvasSize,
    stageSize: stageSize ?? this.stageSize,
    userPan: userPan ?? this.userPan,
    userZoom: userZoom ?? this.userZoom,
    cameraCenter: cameraCenter ?? this.cameraCenter,
    cameraZoom: cameraZoom ?? this.cameraZoom,
    cameraRotation: cameraRotation ?? this.cameraRotation,
    padding: padding ?? this.padding,
  );

  /// Clamps zoom so the user cannot get lost at 3000x or shrink to nothing.
  StageViewport withClampedZoom() {
    final z = userZoom.clamp(0.15, 12.0);
    return userZoom == z ? this : copyWith(userZoom: z);
  }
}

/// Helpers shared by the painter and the gesture recognisers.
extension ViewportShortcuts on Size {
  Vec2 get centerVec => Vec2(width / 2, height / 2);
}

/// Converts a scene-space length to pixels (for constant-width gizmos).
double sceneLengthToPx(double length, StageViewport vp) => length * vp.scale;
