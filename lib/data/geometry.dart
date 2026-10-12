import 'dart:math' as math;

/// Immutable 2D point/vector. Used everywhere instead of [Offset] so the
/// model layer stays free of Flutter imports and can be unit-tested on its own.
class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  static const zero = Vec2(0, 0);

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
  Vec2 operator /(double s) => Vec2(x / s, y / s);

  double get length => math.sqrt(x * x + y * y);
  double get lengthSquared => x * x + y * y;

  /// Angle in radians, measured from the +X axis.
  double get angle => math.atan2(y, x);

  Vec2 get normalized {
    final l = length;
    if (l < 1e-9) return zero;
    return Vec2(x / l, y / l);
  }

  Vec2 rotated(double radians) {
    final c = math.cos(radians), s = math.sin(radians);
    return Vec2(x * c - y * s, x * s + y * c);
  }

  Vec2 get perpendicular => Vec2(-y, x);

  double distanceTo(Vec2 o) => (this - o).length;

  static Vec2 lerp(Vec2 a, Vec2 b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
  }

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  static Vec2 fromJson(Map<String, dynamic> j) => Vec2(
    (j['x'] as num?)?.toDouble() ?? 0,
    (j['y'] as num?)?.toDouble() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Local -> parent mapping for a scene object.
class Transform2D {
  const Transform2D({
    this.translation = Vec2.zero,
    this.rotation = 0,
    this.scale = 1,
  });

  final Vec2 translation;
  final double rotation;
  final double scale;

  static const identity = Transform2D();

  Transform2D copyWith({Vec2? translation, double? rotation, double? scale}) =>
      Transform2D(
        translation: translation ?? this.translation,
        rotation: rotation ?? this.rotation,
        scale: scale ?? this.scale,
      );

  Vec2 applyLocal(Vec2 p) {
    final r = p.rotated(rotation) * scale;
    return r + translation;
  }

  /// Transform a point expressed in this space into the parent's space.
  Vec2 toParent(Vec2 p) => applyLocal(p);

  Transform2D compose(Transform2D outer) {
    // outer * this
    final t =
        outer.translation +
        this.translation.rotated(outer.rotation) * outer.scale;
    return Transform2D(
      translation: t,
      rotation: outer.rotation + this.rotation,
      scale: outer.scale * this.scale,
    );
  }

  Transform2D interpolated(Transform2D other, double t) {
    // Take the shorter way around the circle so a 350deg -> 10deg tween does
    // not spin the object all the way around.
    var delta = other.rotation - rotation;
    while (delta > math.pi) delta -= 2 * math.pi;
    while (delta < -math.pi) delta += 2 * math.pi;
    return Transform2D(
      translation: Vec2.lerp(translation, other.translation, t),
      rotation: rotation + delta * t,
      scale: translation == other.translation
          ? (t < 0.5 ? scale : other.scale)
          : scale + (other.scale - scale) * t,
    );
  }

  Map<String, dynamic> toJson() => {
    'translation': translation.toJson(),
    'rotation': rotation,
    'scale': scale,
  };

  static Transform2D fromJson(Map<String, dynamic> j) => Transform2D(
    translation: Vec2.fromJson(
      (j['translation'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
    scale: (j['scale'] as num?)?.toDouble() ?? 1,
  );
}

/// Axis-aligned rectangle in scene space.
class Rect2 {
  const Rect2(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  Vec2 get center => Vec2((left + right) / 2, (top + bottom) / 2);
  bool get isEmpty => width <= 0 || height <= 0;

  bool contains(Vec2 p) =>
      p.x >= left && p.x <= right && p.y >= top && p.y <= bottom;

  Rect2 expanded(double by) =>
      Rect2(left - by, top - by, right + by, bottom + by);

  Rect2? union(Rect2? other) {
    if (other == null || other.isEmpty) return this;
    if (isEmpty) return other;
    return Rect2(
      math.min(left, other.left),
      math.min(top, other.top),
      math.max(right, other.right),
      math.max(bottom, other.bottom),
    );
  }

  Rect2 transformedBy(Transform2D t) {
    final corners = [
      applyLocal(t, Vec2(left, top)),
      applyLocal(t, Vec2(right, top)),
      applyLocal(t, Vec2(right, bottom)),
      applyLocal(t, Vec2(left, bottom)),
    ];
    var l = corners.first.x, r = corners.first.x;
    var tp = corners.first.y, b = corners.first.y;
    for (final c in corners.skip(1)) {
      l = math.min(l, c.x);
      r = math.max(r, c.x);
      tp = math.min(tp, c.y);
      b = math.max(b, c.y);
    }
    return Rect2(l, tp, r, b);
  }

  static Vec2 applyLocal(Transform2D t, Vec2 p) => t.applyLocal(p);

  Map<String, dynamic> toJson() => {
    'l': left,
    't': top,
    'r': right,
    'b': bottom,
  };

  static Rect2 fromJson(Map<String, dynamic> j) => Rect2(
    (j['l'] as num?)?.toDouble() ?? 0,
    (j['t'] as num?)?.toDouble() ?? 0,
    (j['r'] as num?)?.toDouble() ?? 0,
    (j['b'] as num?)?.toDouble() ?? 0,
  );

  @override
  String toString() => 'Rect2($left, $top, $right, $bottom)';
}

/// Convenience: clamp a double into a range.
double clampDouble(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Round to a stable number of decimals so JSON output stays small and diffs
/// stay readable between saves.
double roundTo(double v, [int decimals = 3]) {
  final f = 1.0 / math.pow(10, decimals);
  return (v * f).roundToDouble() / f;
}
