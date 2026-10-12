import '../data/geometry.dart';
import '../data/models.dart';

/// Everything needed to draw one (possibly fractional) frame.
///
/// Playback, onion skin, the editor canvas and the exporter all go through
/// this one function, which is the only way to guarantee "what you see is
/// what you export".
class ResolvedScene {
  ResolvedScene({
    required this.layers,
    required this.camera,
    required this.indexA,
    required this.indexB,
    required this.t,
  });

  final List<Layer> layers;
  final CameraKey camera;
  final int indexA;
  final int indexB;
  final double t;

  static ResolvedScene empty() => ResolvedScene(
    layers: const [],
    camera: CameraKey.defaultCamera,
    indexA: 0,
    indexB: 0,
    t: 0,
  );
}

/// Resolves the scene at a fractional frame position.
///
/// [framePosition] is in *frame* units (1.0 == one whole frame). Values between
/// two frames are tweened; the weight is exposed as `t` so callers can draw
/// onion skin for the neighbours.
ResolvedScene resolveScene(
  Sequence seq,
  double framePosition, {
  int depth = 0,
}) {
  if (seq.frames.isEmpty) return ResolvedScene.empty();

  final count = seq.frames.length;
  final clamped = framePosition.clamp(0.0, (count - 1).toDouble());
  final indexA = clamped.floor();
  final indexB = clamped.ceil();
  final t = clamped - indexA;

  final a = seq.frames[indexA];
  final b = seq.frames[indexB];

  final camA = a.camera ?? CameraKey.defaultCamera;
  final camB = (b.camera ?? a.camera) ?? CameraKey.defaultCamera;

  return ResolvedScene(
    layers: interpolateLayers(a.layers, b.layers, t),
    camera: indexA == indexB ? camA : camA.interpolated(camB, t),
    indexA: indexA,
    indexB: indexB,
    t: t,
  );
}

/// Layers are matched by id. A layer that exists in only one of the two frames
/// fades in or out instead of popping.
List<Layer> interpolateLayers(List<Layer> a, List<Layer> b, double t) {
  if (t <= 0) return a;
  if (t >= 1) return b;

  final byIdB = {for (final l in b) l.id: l};
  final byIdA = {for (final l in a) l.id: l};

  final result = <Layer>[];

  for (final la in a) {
    final lb = byIdB[la.id];
    if (lb == null) {
      // Fading out: keep the shape, drop the opacity.
      result.add(la.copyShallow(opacity: la.opacity * (1 - t)));
      continue;
    }
    result.add(
      Layer(
        id: la.id,
        name: lb.name,
        parentId: lb.parentId ?? la.parentId,
        visible: lb.visible,
        locked: lb.locked,
        opacity: _lerp(la.opacity, lb.opacity, t),
        objects: interpolateObjects(la.objects, lb.objects, t),
      ),
    );
  }

  for (final lb in b) {
    if (!byIdA.containsKey(lb.id)) {
      result.add(lb.copyShallow(opacity: lb.opacity * t));
    }
  }

  return result;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Interpolates two object lists, matching by id.
List<SceneObject> interpolateObjects(
  List<SceneObject> a,
  List<SceneObject> b,
  double t,
) {
  if (t <= 0) return a;
  if (t >= 1) return b;

  final byIdB = {for (final o in b) o.id: o};
  final byIdA = {for (final o in a) o.id: o};
  final result = <SceneObject>[];

  for (final oa in a) {
    final ob = byIdB[oa.id];
    if (ob == null) {
      result.add(oa.withOpacity(oa.opacity * (1 - t)));
      continue;
    }
    result.add(interpolateObject(oa, ob, t));
  }
  for (final ob in b) {
    if (!byIdA.containsKey(ob.id)) {
      result.add(ob.withOpacity(ob.opacity * t));
    }
  }
  return result;
}

SceneObject interpolateObject(SceneObject a, SceneObject b, double t) {
  if (a.kind != b.kind) {
    // Kind changed between frames (e.g. the user converted the object):
    // cross-fade instead of crashing.
    return t < 0.5 ? a : b;
  }

  final transform = a.transform.interpolated(b.transform, t);
  final opacity = _lerp(a.opacity, b.opacity, t);
  final visible = t < 0.5 ? a.visible : b.visible;
  final name = t < 0.5 ? a.name : b.name;

  return switch (a) {
    final StrokeObject x => StrokeObject(
      id: x.id,
      points: _lerpPoints(x.points, (b as StrokeObject).points, t),
      color: t < 0.5 ? x.color : b.color,
      thickness: _lerp(x.thickness, b.thickness, t),
      closed: t < 0.5 ? x.closed : b.closed,
      cap: t < 0.5 ? x.cap : b.cap,
      name: name,
      transform: transform,
      visible: visible,
      locked: x.locked,
      opacity: opacity,
    ),
    final CircleObject x => CircleObject(
      id: x.id,
      center: Vec2.lerp(x.center, (b as CircleObject).center, t),
      radius: _lerp(x.radius, b.radius, t),
      color: t < 0.5 ? x.color : b.color,
      thickness: _lerp(x.thickness, b.thickness, t),
      filled: t < 0.5 ? x.filled : b.filled,
      name: name,
      transform: transform,
      visible: visible,
      locked: x.locked,
      opacity: opacity,
    ),
    final FillObject x => FillObject(
      id: x.id,
      points: _lerpPoints(x.points, (b as FillObject).points, t),
      color: t < 0.5 ? x.color : b.color,
      name: name,
      transform: transform,
      visible: visible,
      locked: x.locked,
      opacity: opacity,
    ),
    final FigureObject x => _interpolateFigure(
      x,
      b as FigureObject,
      t,
      transform: transform,
      opacity: opacity,
      visible: visible,
      name: name,
    ),
    final TextObject x => _interpText(
      x,
      b as TextObject,
      t,
      transform: transform,
      opacity: opacity,
      visible: visible,
      name: name,
    ),
    final SpriteObject x => _interpSprite(
      x,
      b as SpriteObject,
      t,
      transform: transform,
      opacity: opacity,
      visible: visible,
      name: name,
    ),
    final MovieclipObject x => _interpMovieclip(
      x,
      b as MovieclipObject,
      t,
      transform: transform,
      opacity: opacity,
      visible: visible,
      name: name,
    ),
  };
}

TextObject _interpText(
  TextObject a,
  TextObject b,
  double t, {
  required Transform2D transform,
  required double opacity,
  required bool visible,
  required String name,
}) => TextObject(
  id: a.id,
  // Text does not cross-fade: swapping at the midpoint is far less
  // confusing than two sentences sliding into each other.
  text: t < 0.5 ? a.text : b.text,
  fontSize: _lerp(a.fontSize, b.fontSize, t),
  color: t < 0.5 ? a.color : b.color,
  backgroundColor: t < 0.5 ? a.backgroundColor : b.backgroundColor,
  bubble: t < 0.5 ? a.bubble : b.bubble,
  align: t < 0.5 ? a.align : b.align,
  padding: _lerp(a.padding, b.padding, t),
  outlineColor: t < 0.5 ? a.outlineColor : b.outlineColor,
  name: name,
  transform: transform,
  visible: visible,
  locked: a.locked,
  opacity: opacity,
);

SpriteObject _interpSprite(
  SpriteObject a,
  SpriteObject b,
  double t, {
  required Transform2D transform,
  required double opacity,
  required bool visible,
  required String name,
}) => SpriteObject(
  id: a.id,
  // Both frames may point at different images (the user swapped the
  // sprite). Switch hard rather than blend nonsense.
  assetPath: t < 0.5 ? a.assetPath : b.assetPath,
  naturalWidth: _lerp(a.naturalWidth, b.naturalWidth, t),
  naturalHeight: _lerp(a.naturalHeight, b.naturalHeight, t),
  spriteFrames: t < 0.5 ? a.spriteFrames : b.spriteFrames,
  spriteFps: t < 0.5 ? a.spriteFps : b.spriteFps,
  spriteColumns: t < 0.5 ? a.spriteColumns : b.spriteColumns,
  spriteRows: t < 0.5 ? a.spriteRows : b.spriteRows,
  name: name,
  transform: transform,
  visible: visible,
  locked: a.locked,
  opacity: opacity,
);

MovieclipObject _interpMovieclip(
  MovieclipObject a,
  MovieclipObject b,
  double t, {
  required Transform2D transform,
  required double opacity,
  required bool visible,
  required String name,
}) => MovieclipObject(
  id: a.id,
  clipId: t < 0.5 ? a.clipId : b.clipId,
  startFrame: _lerp(
    a.startFrame.toDouble(),
    b.startFrame.toDouble(),
    t,
  ).round(),
  lengthFrames: _lerp(
    a.lengthFrames.toDouble(),
    b.lengthFrames.toDouble(),
    t,
  ).round(),
  loop: t < 0.5 ? a.loop : b.loop,
  timeScale: _lerp(a.timeScale, b.timeScale, t),
  name: name,
  transform: transform,
  visible: visible,
  locked: a.locked,
  opacity: opacity,
);

FigureObject _interpolateFigure(
  FigureObject a,
  FigureObject b,
  double t, {
  required Transform2D transform,
  required double opacity,
  required bool visible,
  required String name,
}) {
  // Anchors drive the skeleton. Interpolate every anchor present in both,
  // then let the bone table follow.
  final anchors = <Anchor, Vec2>{};
  for (final e in a.anchors.entries) {
    final other = b.anchors[e.key];
    anchors[e.key] = other == null ? e.value : Vec2.lerp(e.value, other, t);
  }
  // Anchors that only exist in B fade in from the nearest B anchor so the
  // figure does not gain a floating arm at the midpoint.
  for (final e in b.anchors.entries) {
    if (anchors.containsKey(e.key)) continue;
    final nearest = _nearestAnchorPosition(b.anchors, e.key);
    anchors[e.key] = nearest == null ? e.value : Vec2.lerp(nearest, e.value, t);
  }

  final boneCount = a.bones.length < b.bones.length
      ? a.bones.length
      : b.bones.length;
  final bones = <Bone>[];
  for (var i = 0; i < boneCount; i++) {
    final ba = a.bones[i];
    final bb = b.bones[i];
    bones.add(
      Bone(
        name: t < 0.5 ? ba.name : bb.name,
        a: Vec2.lerp(ba.a, bb.a, t),
        b: Vec2.lerp(ba.b, bb.b, t),
        thickness: _lerp(ba.thickness, bb.thickness, t),
        color: t < 0.5 ? ba.color : bb.color,
        cap: t < 0.5 ? ba.cap : bb.cap,
        anchorA: t < 0.5 ? ba.anchorA : bb.anchorA,
        anchorB: t < 0.5 ? ba.anchorB : bb.anchorB,
      ),
    );
  }
  for (var i = boneCount; i < a.bones.length; i++) {
    bones.add(a.bones[i].copy());
  }

  return FigureObject(
    id: a.id,
    name: name,
    bones: bones,
    joints: t < 0.5 ? a.joints : b.joints,
    anchors: anchors,
    thickness: _lerp(a.thickness, b.thickness, t),
    color: t < 0.5 ? a.color : b.color,
    showJoints: a.showJoints || b.showJoints,
    transform: transform,
    visible: visible,
    locked: a.locked,
    opacity: opacity,
  );
}

Vec2? _nearestAnchorPosition(Map<Anchor, Vec2> anchors, Anchor from) {
  final origin = anchors[from];
  if (origin == null) return null;
  Vec2? best;
  var bestDist = double.infinity;
  for (final e in anchors.entries) {
    if (e.key == from) continue;
    final d = (e.value - origin).lengthSquared;
    if (d < bestDist) {
      bestDist = d;
      best = e.value;
    }
  }
  return best;
}

List<Vec2> _lerpPoints(List<Vec2> a, List<Vec2> b, double t) {
  final n = a.length < b.length ? a.length : b.length;
  final out = <Vec2>[];
  for (var i = 0; i < n; i++) {
    out.add(Vec2.lerp(a[i], b[i], t));
  }
  for (var i = n; i < a.length; i++) {
    out.add(a[i]);
  }
  for (var i = n; i < b.length; i++) {
    out.add(b[i]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Movieclip expansion
// ---------------------------------------------------------------------------

/// Replaces [MovieclipObject]s with the real objects of their clip, so the
/// painter only ever deals with primitives.
///
/// [lookup] resolves a clip id to its sequence. [framePosition] is the position
/// *inside* the parent animation, which the per-instance [MovieclipObject
/// .startFrame] / [.timeScale] then map into clip-local time.
///
/// [depth] stops a clip that (directly or indirectly) contains itself from
/// recursing forever. Depth 3 is far more nesting than anyone actually uses.
List<SceneObject> expandMovieclips(
  List<SceneObject> objects,
  Sequence? Function(String clipId) lookup,
  double framePosition,
  int depth,
) {
  if (depth > 3 || objects.isEmpty) return objects;

  final out = <SceneObject>[];
  var found = false;

  for (final o in objects) {
    if (o is! MovieclipObject) {
      out.add(o);
      continue;
    }
    found = true;

    final seq = lookup(o.clipId);
    if (seq == null || seq.frames.isEmpty) {
      out.add(o);
      continue;
    }

    final clipLength = seq.frames.length.toDouble();
    final local =
        ((framePosition - o.startFrame) / o.lengthFrames.clamp(1, 1 << 30)) *
        clipLength *
        o.timeScale;

    final wrapped = o.loop
        ? (local % clipLength + clipLength) % clipLength
        : local.clamp(0.0, clipLength - 1);

    final clipScene = resolveScene(seq, wrapped);
    final children = expandMovieclips(
      clipScene.layers.expand((l) => l.objects).toList(),
      lookup,
      wrapped,
      depth + 1,
    );

    for (final child in children) {
      out.add(_composeInto(child, o.transform, o.opacity));
    }
  }

  // Nothing expanded: hand back the original list untouched.
  return found ? out : objects;
}

/// Bakes [outer] into [child] so nested clips render as one flat object.
SceneObject _composeInto(
  SceneObject child,
  Transform2D outer,
  double outerOpacity,
) {
  final composed = child.transform.compose(outer);
  final faded = (child.opacity * outerOpacity).clamp(0.0, 1.0);
  return _rebuild(child, composed, faded);
}

SceneObject _rebuild(SceneObject o, Transform2D t, double opacity) {
  switch (o) {
    case final StrokeObject x:
      return StrokeObject(
        id: x.id,
        points: x.points,
        color: x.color,
        thickness: x.thickness,
        closed: x.closed,
        cap: x.cap,
        name: x.name,
        transform: t,
        visible: x.visible,
        locked: x.locked,
        opacity: opacity,
      );
    case final CircleObject x:
      return CircleObject(
        id: x.id,
        center: x.center,
        radius: x.radius,
        color: x.color,
        thickness: x.thickness,
        filled: x.filled,
        name: x.name,
        transform: t,
        visible: x.visible,
        locked: x.locked,
        opacity: opacity,
      );
    case final FillObject x:
      return FillObject(
        id: x.id,
        points: x.points,
        color: x.color,
        name: x.name,
        transform: t,
        visible: x.visible,
        locked: x.locked,
        opacity: opacity,
      );
    case final FigureObject x:
      return FigureObject(
        id: x.id,
        bones: x.bones,
        joints: x.joints,
        anchors: x.anchors,
        thickness: x.thickness,
        color: x.color,
        showJoints: x.showJoints,
        name: x.name,
        transform: t,
        visible: x.visible,
        locked: x.locked,
        opacity: opacity,
      );
    case final TextObject x:
      return TextObject(
        id: x.id,
        text: x.text,
        fontSize: x.fontSize,
        color: x.color,
        backgroundColor: x.backgroundColor,
        bubble: x.bubble,
        align: x.align,
        padding: x.padding,
        outlineColor: x.outlineColor,
        name: x.name,
        transform: t,
        visible: x.visible,
        locked: x.locked,
        opacity: opacity,
      );
    case final SpriteObject x:
      return SpriteObject(
        id: x.id,
        assetPath: x.assetPath,
        naturalWidth: x.naturalWidth,
        naturalHeight: x.naturalHeight,
        spriteFrames: x.spriteFrames,
        spriteFps: x.spriteFps,
        spriteColumns: x.spriteColumns,
        spriteRows: x.spriteRows,
        name: x.name,
        transform: t,
        visible: x.visible,
        locked: x.locked,
        opacity: opacity,
      );
    case final MovieclipObject x:
      return MovieclipObject(
        id: x.id,
        clipId: x.clipId,
        startFrame: x.startFrame,
        lengthFrames: x.lengthFrames,
        loop: x.loop,
        timeScale: x.timeScale,
        name: x.name,
        transform: t,
        visible: x.visible,
        locked: x.locked,
        opacity: opacity,
      );
  }
}

// ---------------------------------------------------------------------------
// Small helpers the model needs but that live better next to the interpolator
// ---------------------------------------------------------------------------

extension LayerCopy on Layer {
  Layer copyShallow({double? opacity}) => Layer(
    id: id,
    name: name,
    objects: objects,
    visible: visible,
    locked: locked,
    opacity: opacity ?? this.opacity,
    parentId: parentId,
  );
}

extension ObjectOpacity on SceneObject {
  SceneObject withOpacity(double value) {
    if (value == opacity) return this;
    switch (this) {
      case final StrokeObject s:
        return StrokeObject(
          id: s.id,
          points: s.points,
          color: s.color,
          thickness: s.thickness,
          closed: s.closed,
          cap: s.cap,
          name: s.name,
          transform: s.transform,
          visible: s.visible,
          locked: s.locked,
          opacity: value,
        );
      case final CircleObject s:
        return CircleObject(
          id: s.id,
          center: s.center,
          radius: s.radius,
          color: s.color,
          thickness: s.thickness,
          filled: s.filled,
          name: s.name,
          transform: s.transform,
          visible: s.visible,
          locked: s.locked,
          opacity: value,
        );
      case final FillObject s:
        return FillObject(
          id: s.id,
          points: s.points,
          color: s.color,
          name: s.name,
          transform: s.transform,
          visible: s.visible,
          locked: s.locked,
          opacity: value,
        );
      case final FigureObject s:
        return FigureObject(
          id: s.id,
          bones: s.bones,
          joints: s.joints,
          anchors: s.anchors,
          thickness: s.thickness,
          color: s.color,
          showJoints: s.showJoints,
          name: s.name,
          transform: s.transform,
          visible: s.visible,
          locked: s.locked,
          opacity: value,
        );
      case final TextObject s:
        return TextObject(
          id: s.id,
          text: s.text,
          fontSize: s.fontSize,
          color: s.color,
          backgroundColor: s.backgroundColor,
          bubble: s.bubble,
          align: s.align,
          padding: s.padding,
          outlineColor: s.outlineColor,
          name: s.name,
          transform: s.transform,
          visible: s.visible,
          locked: s.locked,
          opacity: value,
        );
      case final SpriteObject s:
        return SpriteObject(
          id: s.id,
          assetPath: s.assetPath,
          naturalWidth: s.naturalWidth,
          naturalHeight: s.naturalHeight,
          spriteFrames: s.spriteFrames,
          spriteFps: s.spriteFps,
          spriteColumns: s.spriteColumns,
          spriteRows: s.spriteRows,
          name: s.name,
          transform: s.transform,
          visible: s.visible,
          locked: s.locked,
          opacity: value,
        );
      case final MovieclipObject s:
        return MovieclipObject(
          id: s.id,
          clipId: s.clipId,
          startFrame: s.startFrame,
          lengthFrames: s.lengthFrames,
          loop: s.loop,
          timeScale: s.timeScale,
          name: s.name,
          transform: s.transform,
          visible: s.visible,
          locked: s.locked,
          opacity: value,
        );
    }
  }
}
