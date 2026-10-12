import 'geometry.dart';

/// Current on-disk schema version. Bump when the JSON shape changes and add a
/// step to [ProjectCodec.migrate].
const int kSchemaVersion = 2;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Discriminator for every drawable thing that can live inside a layer.
enum ObjectKind { stroke, circle, figure, fill, text, sprite, movieclip }

enum CapStyle { round, square, butt }

enum LabelAlign { left, center, right }

enum BubbleStyle { none, rounded, tailLeft, tailRight }

enum Anchor {
  head,
  neck,
  chest,
  hip,
  kneeL,
  kneeR,
  footL,
  footR,
  shoulderL,
  shoulderR,
  elbowL,
  elbowR,
  handL,
  handR,
  waist,
}

extension AnchorX on Anchor {
  String get key => name;
  static Anchor byKey(String k) =>
      Anchor.values.firstWhere((a) => a.name == k, orElse: () => Anchor.hip);
}

// ---------------------------------------------------------------------------
// Figure primitives
// ---------------------------------------------------------------------------

/// A limb segment inside a stick figure. [a] and [b] are local to the figure's
/// own origin, so moving the figure never has to touch its bones.
class Bone {
  Bone({
    required this.name,
    required this.a,
    required this.b,
    this.thickness = 6,
    this.color = 0xFF1A1A1A,
    this.cap = CapStyle.round,
    this.anchorA,
    this.anchorB,
  });

  String name;
  Vec2 a;
  Vec2 b;
  double thickness;
  int color;
  CapStyle cap;

  /// When both are set and the owning figure carries those anchors, the bone
  /// endpoints are derived from the anchors instead of from [a]/[b]. That is
  /// what lets a pose tween into the next pose instead of just sliding over.
  Anchor? anchorA;
  Anchor? anchorB;

  Bone copy() => Bone(
    name: name,
    a: a,
    b: b,
    thickness: thickness,
    color: color,
    cap: cap,
    anchorA: anchorA,
    anchorB: anchorB,
  );

  Map<String, dynamic> toJson() => {
    'n': name,
    'a': a.toJson(),
    'b': b.toJson(),
    't': thickness,
    'c': color,
    'cap': cap.name,
    if (anchorA != null) 'aa': anchorA!.name,
    if (anchorB != null) 'ab': anchorB!.name,
  };

  static Bone fromJson(Map<String, dynamic> j) => Bone(
    name: j['n'] as String? ?? 'bone',
    a: Vec2.fromJson((j['a'] as Map?)?.cast<String, dynamic>() ?? const {}),
    b: Vec2.fromJson((j['b'] as Map?)?.cast<String, dynamic>() ?? const {}),
    thickness: (j['t'] as num?)?.toDouble() ?? 6,
    color: (j['c'] as num?)?.toInt() ?? 0xFF1A1A1A,
    cap: CapStyle.values.firstWhere(
      (e) => e.name == j['cap'],
      orElse: () => CapStyle.round,
    ),
    anchorA: j['aa'] == null ? null : AnchorX.byKey(j['aa'] as String),
    anchorB: j['ab'] == null ? null : AnchorX.byKey(j['ab'] as String),
  );
}

/// A visible joint / control node.
class Joint {
  Joint({
    required this.name,
    required this.p,
    this.radius = 4,
    this.color = 0xFF1A1A1A,
  });

  String name;
  Vec2 p;
  double radius;
  int color;

  Joint copy() => Joint(name: name, p: p, radius: radius, color: color);

  Map<String, dynamic> toJson() => {
    'n': name,
    'p': p.toJson(),
    'r': radius,
    'c': color,
  };

  static Joint fromJson(Map<String, dynamic> j) => Joint(
    name: j['n'] as String? ?? 'joint',
    p: Vec2.fromJson((j['p'] as Map?)?.cast<String, dynamic>() ?? const {}),
    radius: (j['r'] as num?)?.toDouble() ?? 4,
    color: (j['c'] as num?)?.toInt() ?? 0xFF1A1A1A,
  );
}

// ---------------------------------------------------------------------------
// Scene objects
// ---------------------------------------------------------------------------

/// Base class for everything drawable. Sealed so the serializers stay
/// exhaustively checked by the compiler.
sealed class SceneObject {
  String id;
  String name;
  Transform2D transform;
  bool visible;
  bool locked;
  double opacity;

  SceneObject({
    required this.id,
    this.name = '',
    this.transform = Transform2D.identity,
    this.visible = true,
    this.locked = false,
    this.opacity = 1.0,
  });

  ObjectKind get kind;

  /// Where the user grabs this object. Used for hit testing and for gizmos.
  Vec2 get localCenter;

  /// Bounding box in the object's local space (before [transform]).
  Rect2 get localBounds;

  SceneObject duplicate(String newId);

  Map<String, dynamic> toJson();
}

Map<String, dynamic> _baseJson(SceneObject o) => {
  'id': o.id,
  'name': o.name,
  'kind': o.kind.name,
  't': o.transform.toJson(),
  'v': o.visible,
  'l': o.locked,
  'o': o.opacity,
};

class StrokeObject extends SceneObject {
  StrokeObject({
    required super.id,
    required this.points,
    this.color = 0xFF1A1A1A,
    this.thickness = 6,
    this.closed = false,
    this.cap = CapStyle.round,
    super.name,
    super.transform,
    super.visible,
    super.locked,
    super.opacity,
  });

  List<Vec2> points;
  int color;
  double thickness;
  bool closed;
  CapStyle cap;

  @override
  ObjectKind get kind => ObjectKind.stroke;

  @override
  Vec2 get localCenter {
    if (points.isEmpty) return Vec2.zero;
    var x = 0.0, y = 0.0;
    for (final p in points) {
      x += p.x;
      y += p.y;
    }
    return Vec2(x / points.length, y / points.length);
  }

  @override
  Rect2 get localBounds {
    if (points.isEmpty) return const Rect2(0, 0, 0, 0);
    var l = points.first.x, r = l, t = points.first.y, b = t;
    for (final p in points) {
      if (p.x < l) l = p.x;
      if (p.x > r) r = p.x;
      if (p.y < t) t = p.y;
      if (p.y > b) b = p.y;
    }
    return Rect2(
      l - thickness / 2,
      t - thickness / 2,
      r + thickness / 2,
      b + thickness / 2,
    );
  }

  @override
  StrokeObject duplicate(String newId) => StrokeObject(
    id: newId,
    points: points.map((p) => p).toList(),
    color: color,
    thickness: thickness,
    closed: closed,
    cap: cap,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(this),
    'pts': points.map((p) => p.toJson()).toList(),
    'c': color,
    't2': thickness,
    'closed': closed,
    'cap': cap.name,
  };
}

class CircleObject extends SceneObject {
  CircleObject({
    required super.id,
    this.center = Vec2.zero,
    this.radius = 24,
    this.color = 0xFF1A1A1A,
    this.thickness = 6,
    this.filled = false,
    super.name,
    super.transform,
    super.visible,
    super.locked,
    super.opacity,
  });

  Vec2 center;
  double radius;
  int color;
  double thickness;
  bool filled;

  @override
  ObjectKind get kind => ObjectKind.circle;

  @override
  Vec2 get localCenter => center;

  @override
  Rect2 get localBounds => Rect2(
    center.x - radius,
    center.y - radius,
    center.x + radius,
    center.y + radius,
  );

  @override
  CircleObject duplicate(String newId) => CircleObject(
    id: newId,
    center: center,
    radius: radius,
    color: color,
    thickness: thickness,
    filled: filled,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(this),
    'c2': center.toJson(),
    'r': radius,
    'c': color,
    't2': thickness,
    'filled': filled,
  };
}

/// A filled polygon. Used for background paint fills and body masses.
class FillObject extends SceneObject {
  FillObject({
    required super.id,
    required this.points,
    this.color = 0xFF3B82F6,
    super.name,
    super.transform,
    super.visible,
    super.locked,
    super.opacity,
  });

  List<Vec2> points;
  int color;

  @override
  ObjectKind get kind => ObjectKind.fill;

  @override
  Vec2 get localCenter {
    if (points.isEmpty) return Vec2.zero;
    var x = 0.0, y = 0.0;
    for (final p in points) {
      x += p.x;
      y += p.y;
    }
    return Vec2(x / points.length, y / points.length);
  }

  @override
  Rect2 get localBounds {
    if (points.isEmpty) return const Rect2(0, 0, 0, 0);
    var l = points.first.x, r = l, t = points.first.y, b = t;
    for (final p in points) {
      if (p.x < l) l = p.x;
      if (p.x > r) r = p.x;
      if (p.y < t) t = p.y;
      if (p.y > b) b = p.y;
    }
    return Rect2(l, t, r, b);
  }

  @override
  FillObject duplicate(String newId) => FillObject(
    id: newId,
    points: points.map((p) => p).toList(),
    color: color,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(this),
    'pts': points.map((p) => p.toJson()).toList(),
    'c': color,
  };
}

/// The stick figure. Holds its own bone list plus named anchors, which is what
/// makes tweening between frames possible.
/// Fills each bone's `a`/`b` from the anchors it references.
///
/// Lives here rather than in stick_rigs.dart because it is a property of the
/// model: any code that moves an anchor has to re-resolve, and the data layer
/// cannot depend on the editor layer.
FigureObject resolveFigure(FigureObject fig) {
  final bones = fig.bones.map((b) {
    final copy = b.copy();
    final anchorA = b.anchorA;
    final anchorB = b.anchorB;
    if (anchorA != null) {
      final p = fig.anchors[anchorA];
      if (p != null) copy.a = p;
    }
    if (anchorB != null) {
      final p = fig.anchors[anchorB];
      if (p != null) copy.b = p;
    }
    return copy;
  }).toList();

  return FigureObject(
    id: fig.id,
    name: fig.name,
    bones: bones,
    joints: fig.joints,
    anchors: Map<Anchor, Vec2>.from(fig.anchors),
    thickness: fig.thickness,
    color: fig.color,
    showJoints: fig.showJoints,
    transform: fig.transform,
    visible: fig.visible,
    locked: fig.locked,
    opacity: fig.opacity,
  );
}

class FigureObject extends SceneObject {
  FigureObject({
    required super.id,
    required this.bones,
    List<Joint>? joints,
    Map<Anchor, Vec2>? anchors,
    this.thickness = 6,
    this.color = 0xFF1A1A1A,
    this.showJoints = false,
    super.name,
    super.transform,
    super.visible,
    super.locked,
    super.opacity,
  }) : joints = joints ?? <Joint>[],
       anchors = anchors ?? <Anchor, Vec2>{};

  List<Bone> bones;
  List<Joint> joints;
  Map<Anchor, Vec2> anchors;
  double thickness;
  int color;
  bool showJoints;

  @override
  ObjectKind get kind => ObjectKind.figure;

  @override
  Vec2 get localCenter {
    if (anchors.isNotEmpty) {
      var x = 0.0, y = 0.0;
      anchors.values.forEach((v) {
        x += v.x;
        y += v.y;
      });
      return Vec2(x / anchors.length, y / anchors.length);
    }
    if (bones.isEmpty) return Vec2.zero;
    var x = 0.0, y = 0.0;
    for (final b in bones) {
      x += (b.a.x + b.b.x) / 2;
      y += (b.a.y + b.b.y) / 2;
    }
    return Vec2(x / bones.length, y / bones.length);
  }

  @override
  Rect2 get localBounds {
    Rect2? box;
    for (final b in bones) {
      box = box?.union(
        Rect2(
          b.a.x < b.b.x ? b.a.x : b.b.x,
          b.a.y < b.b.y ? b.a.y : b.b.y,
          b.a.x > b.b.x ? b.a.x : b.b.x,
          b.a.y > b.b.y ? b.a.y : b.b.y,
        ),
      );
    }
    return box ?? const Rect2(0, 0, 0, 0);
  }

  /// Copy under [newId] with optional overrides. The pose editor uses this to
  /// swap a pose while keeping the figure's identity, which is what lets the
  /// tweener match it against the neighbouring frames.
  FigureObject copy(
    String newId, {
    Map<Anchor, Vec2>? anchors,
    int? color,
    double? thickness,
  }) => resolveFigure(
    FigureObject(
      id: newId,
      bones: bones,
      joints: joints,
      anchors: anchors ?? Map<Anchor, Vec2>.from(this.anchors),
      thickness: thickness ?? this.thickness,
      color: color ?? this.color,
      showJoints: showJoints,
      name: name,
      transform: transform,
      visible: visible,
      locked: locked,
      opacity: opacity,
    ),
  );

  @override
  FigureObject duplicate(String newId) => FigureObject(
    id: newId,
    bones: bones.map((b) => b.copy()).toList(),
    joints: joints.map((j) => j.copy()).toList(),
    anchors: Map<Anchor, Vec2>.from(anchors),
    thickness: thickness,
    color: color,
    showJoints: showJoints,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(this),
    'bones': bones.map((b) => b.toJson()).toList(),
    'joints': joints.map((j) => j.toJson()).toList(),
    'anchors': {for (final e in anchors.entries) e.key.name: e.value.toJson()},
    't2': thickness,
    'c': color,
    'sj': showJoints,
  };
}

class TextObject extends SceneObject {
  TextObject({
    required super.id,
    required this.text,
    this.fontSize = 28,
    this.color = 0xFF111111,
    this.backgroundColor,
    this.bubble = BubbleStyle.rounded,
    this.align = LabelAlign.center,
    this.padding = 10,
    this.outlineColor = 0xFFFFFFFF,
    super.name,
    super.transform,
    super.visible,
    super.locked,
    super.opacity,
  });

  String text;
  double fontSize;
  int color;
  int? backgroundColor;
  BubbleStyle bubble;
  LabelAlign align;
  double padding;
  int outlineColor;

  @override
  ObjectKind get kind => ObjectKind.text;

  @override
  Vec2 get localCenter => Vec2.zero;

  /// Rough box; the painter refines it with the real text layout.
  @override
  Rect2 get localBounds {
    final lines = text.split('\n');
    final longest = lines.isEmpty
        ? 0
        : lines.map((l) => l.length).reduce((a, b) => a > b ? a : b);
    final w = longest * fontSize * 0.55 + padding * 2;
    final h = lines.length * fontSize * 1.25 + padding * 2;
    return Rect2(-w / 2, -h / 2, w / 2, h / 2);
  }

  /// Returns a copy under [newId], optionally overriding any field. Used by
  /// the text editor so the sheet can preview changes without touching the
  /// project until the user confirms.
  TextObject copy(
    String newId, {
    String? text,
    double? fontSize,
    int? color,
    int? backgroundColor,
    BubbleStyle? bubble,
  }) => TextObject(
    id: newId,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    bubble: bubble ?? this.bubble,
    align: align,
    padding: padding,
    outlineColor: outlineColor,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  TextObject duplicate(String newId) => TextObject(
    id: newId,
    text: text,
    fontSize: fontSize,
    color: color,
    backgroundColor: backgroundColor,
    bubble: bubble,
    align: align,
    padding: padding,
    outlineColor: outlineColor,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(this),
    'text': text,
    'fs': fontSize,
    'c': color,
    'bg': backgroundColor,
    'bub': bubble.name,
    'align': align.name,
    'pad': padding,
    'ol': outlineColor,
  };
}

/// An imported image (PNG/JPG) placed on the stage, optionally animated.
class SpriteObject extends SceneObject {
  SpriteObject({
    required super.id,
    required this.assetPath,
    this.naturalWidth = 64,
    this.naturalHeight = 64,
    this.spriteFrames = 1,
    this.spriteFps = 8,
    this.spriteColumns = 1,
    this.spriteRows = 1,
    super.name,
    super.transform,
    super.visible,
    super.locked,
    super.opacity,
  });

  /// Path relative to the project's media folder.
  String assetPath;
  double naturalWidth;
  double naturalHeight;

  /// >1 turns the image into a horizontal/sprite-sheet strip.
  int spriteFrames;
  double spriteFps;
  int spriteColumns;
  int spriteRows;

  @override
  ObjectKind get kind => ObjectKind.sprite;

  @override
  Vec2 get localCenter => Vec2.zero;

  @override
  Rect2 get localBounds => Rect2(
    -naturalWidth / 2,
    -naturalHeight / 2,
    naturalWidth / 2,
    naturalHeight / 2,
  );

  SpriteObject copy(
    String newId, {
    String? assetPath,
    double? naturalWidth,
    double? naturalHeight,
    int? spriteFrames,
    double? spriteFps,
    int? spriteColumns,
    int? spriteRows,
  }) => SpriteObject(
    id: newId,
    assetPath: assetPath ?? this.assetPath,
    naturalWidth: naturalWidth ?? this.naturalWidth,
    naturalHeight: naturalHeight ?? this.naturalHeight,
    spriteFrames: spriteFrames ?? this.spriteFrames,
    spriteFps: spriteFps ?? this.spriteFps,
    spriteColumns: spriteColumns ?? this.spriteColumns,
    spriteRows: spriteRows ?? this.spriteRows,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  SpriteObject duplicate(String newId) => SpriteObject(
    id: newId,
    assetPath: assetPath,
    naturalWidth: naturalWidth,
    naturalHeight: naturalHeight,
    spriteFrames: spriteFrames,
    spriteFps: spriteFps,
    spriteColumns: spriteColumns,
    spriteRows: spriteRows,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(this),
    'p': assetPath,
    'nw': naturalWidth,
    'nh': naturalHeight,
    'sf': spriteFrames,
    'sfps': spriteFps,
    'sc': spriteColumns,
    'sr': spriteRows,
  };
}

/// An instance of a reusable sub-animation.
class MovieclipObject extends SceneObject {
  MovieclipObject({
    required super.id,
    required this.clipId,
    this.startFrame = 0,
    this.lengthFrames = 12,
    this.loop = true,
    this.timeScale = 1.0,
    super.name,
    super.transform,
    super.visible,
    super.locked,
    super.opacity,
  });

  String clipId;
  int startFrame;
  int lengthFrames;
  bool loop;
  double timeScale;

  @override
  ObjectKind get kind => ObjectKind.movieclip;

  @override
  Vec2 get localCenter => Vec2.zero;

  @override
  Rect2 get localBounds => const Rect2(-10, -10, 10, 10);

  @override
  MovieclipObject duplicate(String newId) => MovieclipObject(
    id: newId,
    clipId: clipId,
    startFrame: startFrame,
    lengthFrames: lengthFrames,
    loop: loop,
    timeScale: timeScale,
    name: name,
    transform: transform,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(this),
    'clip': clipId,
    'sf': startFrame,
    'lf': lengthFrames,
    'loop': loop,
    'ts': timeScale,
  };
}

// ---------------------------------------------------------------------------
// Deserialization
// ---------------------------------------------------------------------------

SceneObject sceneObjectFromJson(Map<String, dynamic> j) {
  final id = j['id'] as String? ?? 'obj';
  final name = (j['name'] as String?) ?? '';
  final transform = Transform2D.fromJson(
    (j['t'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
  final visible = j['v'] as bool? ?? true;
  final locked = j['l'] as bool? ?? false;
  final opacity = (j['o'] as num?)?.toDouble() ?? 1.0;

  List<Vec2> pts = const [];
  if (j['pts'] is List) {
    pts = (j['pts'] as List)
        .map((e) => Vec2.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  // Parse defensively: an unknown kind (older/newer file) must not throw.
  final ObjectKind kind =
      ObjectKind.values.asNameMap()[j['kind'] as String? ?? ''] ??
      ObjectKind.stroke;

  switch (kind) {
    case ObjectKind.stroke:
      return StrokeObject(
        id: id,
        points: pts,
        color: (j['c'] as num?)?.toInt() ?? 0xFF1A1A1A,
        thickness: (j['t2'] as num?)?.toDouble() ?? 6,
        closed: j['closed'] as bool? ?? false,
        cap: CapStyle.values.firstWhere(
          (e) => e.name == j['cap'],
          orElse: () => CapStyle.round,
        ),
        name: name,
        transform: transform,
        visible: visible,
        locked: locked,
        opacity: opacity,
      );
    case ObjectKind.circle:
      return CircleObject(
        id: id,
        center: Vec2.fromJson(
          (j['c2'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        radius: (j['r'] as num?)?.toDouble() ?? 24,
        color: (j['c'] as num?)?.toInt() ?? 0xFF1A1A1A,
        thickness: (j['t2'] as num?)?.toDouble() ?? 6,
        filled: j['filled'] as bool? ?? false,
        name: name,
        transform: transform,
        visible: visible,
        locked: locked,
        opacity: opacity,
      );
    case ObjectKind.fill:
      return FillObject(
        id: id,
        points: pts,
        color: (j['c'] as num?)?.toInt() ?? 0xFF3B82F6,
        name: name,
        transform: transform,
        visible: visible,
        locked: locked,
        opacity: opacity,
      );
    case ObjectKind.figure:
      final bones = <Bone>[];
      if (j['bones'] is List) {
        for (final e in j['bones'] as List) {
          bones.add(Bone.fromJson((e as Map).cast<String, dynamic>()));
        }
      }
      final joints = <Joint>[];
      if (j['joints'] is List) {
        for (final e in j['joints'] as List) {
          joints.add(Joint.fromJson((e as Map).cast<String, dynamic>()));
        }
      }
      final anchors = <Anchor, Vec2>{};
      final rawAnchors =
          (j['anchors'] as Map?)?.cast<String, dynamic>() ?? const {};
      rawAnchors.forEach((k, v) {
        anchors[AnchorX.byKey(k)] = Vec2.fromJson(
          (v as Map).cast<String, dynamic>(),
        );
      });
      return FigureObject(
        id: id,
        bones: bones,
        joints: joints,
        anchors: anchors,
        thickness: (j['t2'] as num?)?.toDouble() ?? 6,
        color: (j['c'] as num?)?.toInt() ?? 0xFF1A1A1A,
        showJoints: j['sj'] as bool? ?? false,
        name: name,
        transform: transform,
        visible: visible,
        locked: locked,
        opacity: opacity,
      );
    case ObjectKind.text:
      return TextObject(
        id: id,
        text: j['text'] as String? ?? '',
        fontSize: (j['fs'] as num?)?.toDouble() ?? 28,
        color: (j['c'] as num?)?.toInt() ?? 0xFF111111,
        backgroundColor: (j['bg'] as num?)?.toInt(),
        bubble: BubbleStyle.values.firstWhere(
          (e) => e.name == j['bub'],
          orElse: () => BubbleStyle.rounded,
        ),
        align: LabelAlign.values.firstWhere(
          (e) => e.name == j['align'],
          orElse: () => LabelAlign.center,
        ),
        padding: (j['pad'] as num?)?.toDouble() ?? 10,
        outlineColor: (j['ol'] as num?)?.toInt() ?? 0xFFFFFFFF,
        name: name,
        transform: transform,
        visible: visible,
        locked: locked,
        opacity: opacity,
      );
    case ObjectKind.sprite:
      return SpriteObject(
        id: id,
        assetPath: j['p'] as String? ?? '',
        naturalWidth: (j['nw'] as num?)?.toDouble() ?? 64,
        naturalHeight: (j['nh'] as num?)?.toDouble() ?? 64,
        spriteFrames: (j['sf'] as num?)?.toInt() ?? 1,
        spriteFps: (j['sfps'] as num?)?.toDouble() ?? 8,
        spriteColumns: (j['sc'] as num?)?.toInt() ?? 1,
        spriteRows: (j['sr'] as num?)?.toInt() ?? 1,
        name: name,
        transform: transform,
        visible: visible,
        locked: locked,
        opacity: opacity,
      );
    case ObjectKind.movieclip:
      return MovieclipObject(
        id: id,
        clipId: j['clip'] as String? ?? '',
        startFrame: (j['sf'] as num?)?.toInt() ?? 0,
        lengthFrames: (j['lf'] as num?)?.toInt() ?? 12,
        loop: j['loop'] as bool? ?? true,
        timeScale: (j['ts'] as num?)?.toDouble() ?? 1.0,
        name: name,
        transform: transform,
        visible: visible,
        locked: locked,
        opacity: opacity,
      );
  }
}

// ---------------------------------------------------------------------------
// Camera, audio, layers, frames
// ---------------------------------------------------------------------------

/// Pan / zoom / rotate for the virtual camera, keyframed per frame.
class CameraKey {
  CameraKey({this.center = Vec2.zero, this.zoom = 1.0, this.rotation = 0});

  Vec2 center;
  double zoom;
  double rotation;

  static final defaultCamera = CameraKey();

  CameraKey copy() => CameraKey(center: center, zoom: zoom, rotation: rotation);

  CameraKey copyWith({Vec2? center, double? zoom, double? rotation}) =>
      CameraKey(
        center: center ?? this.center,
        zoom: zoom ?? this.zoom,
        rotation: rotation ?? this.rotation,
      );

  CameraKey interpolated(CameraKey other, double t) {
    var d = other.rotation - rotation;
    const tau = 6.283185307179586;
    while (d > 3.141592653589793) d -= tau;
    while (d < -3.141592653589793) d += tau;
    return CameraKey(
      center: Vec2.lerp(center, other.center, t),
      zoom: zoom + (other.zoom - zoom) * t,
      rotation: rotation + d * t,
    );
  }

  Map<String, dynamic> toJson() => {
    'c': center.toJson(),
    'z': zoom,
    'r': rotation,
  };

  static CameraKey fromJson(Map<String, dynamic> j) => CameraKey(
    center: Vec2.fromJson(
      (j['c'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    zoom: (j['z'] as num?)?.toDouble() ?? 1.0,
    rotation: (j['r'] as num?)?.toDouble() ?? 0,
  );
}

/// One sound triggered when its frame starts playing.
class AudioCue {
  AudioCue({
    required this.id,
    required this.assetPath,
    this.startFrame = 0,
    this.volume = 1.0,
    this.loop = false,
    this.durationSeconds = 0,
    this.spriteFrames = 0,
  });

  String id;

  /// Relative to the project's media folder.
  String assetPath;

  /// Offset inside the frame, in frames. May be 0.
  int startFrame;
  double volume;
  bool loop;
  double durationSeconds;

  /// Non-zero when the "sound" is really an animated image (GIF/APNG).
  int spriteFrames;

  Map<String, dynamic> toJson() => {
    'id': id,
    'p': assetPath,
    'sf': startFrame,
    'v': volume,
    'loop': loop,
    'd': durationSeconds,
    'sfr': spriteFrames,
  };

  static AudioCue fromJson(Map<String, dynamic> j) => AudioCue(
    id: j['id'] as String? ?? 'cue',
    assetPath: j['p'] as String? ?? '',
    startFrame: (j['sf'] as num?)?.toInt() ?? 0,
    volume: (j['v'] as num?)?.toDouble() ?? 1.0,
    loop: j['loop'] as bool? ?? false,
    durationSeconds: (j['d'] as num?)?.toDouble() ?? 0,
    spriteFrames: (j['sfr'] as num?)?.toInt() ?? 0,
  );
}

/// A looping music bed for the whole sequence.
class AudioTrack {
  AudioTrack({
    required this.id,
    required this.assetPath,
    this.volume = 0.7,
    this.loop = true,
    this.enabled = true,
  });

  String id;
  String assetPath;
  double volume;
  bool loop;
  bool enabled;

  Map<String, dynamic> toJson() => {
    'id': id,
    'p': assetPath,
    'v': volume,
    'loop': loop,
    'on': enabled,
  };

  static AudioTrack fromJson(Map<String, dynamic> j) => AudioTrack(
    id: j['id'] as String? ?? 'track',
    assetPath: j['p'] as String? ?? '',
    volume: (j['v'] as num?)?.toDouble() ?? 0.7,
    loop: j['loop'] as bool? ?? true,
    enabled: j['on'] as bool? ?? true,
  );
}

/// A layer. [parentId] makes layers nestable, which is how "groups" work —
/// there is deliberately no cap on how many groups you can create.
class Layer {
  Layer({
    required this.id,
    required this.name,
    List<SceneObject>? objects,
    this.visible = true,
    this.locked = false,
    this.opacity = 1.0,
    this.parentId,
  }) : objects = objects ?? <SceneObject>[];

  String id;
  String name;
  List<SceneObject> objects;
  bool visible;
  bool locked;
  double opacity;
  String? parentId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'objs': objects.map((o) => o.toJson()).toList(),
    'v': visible,
    'l': locked,
    'o': opacity,
    'parent': parentId,
  };

  static Layer fromJson(Map<String, dynamic> j) => Layer(
    id: j['id'] as String? ?? 'layer',
    name: (j['name'] as String?) ?? 'Layer',
    objects: ((j['objs'] as List?) ?? const [])
        .map((e) => sceneObjectFromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    visible: j['v'] as bool? ?? true,
    locked: j['l'] as bool? ?? false,
    opacity: (j['o'] as num?)?.toDouble() ?? 1.0,
    parentId: j['parent'] as String?,
  );
}

class Frame {
  Frame({
    required this.id,
    List<Layer>? layers,
    List<AudioCue>? audio,
    this.camera,
    this.hold = 1,
  }) : layers = layers ?? <Layer>[],
       audio = audio ?? <AudioCue>[];

  String id;
  List<Layer> layers;
  List<AudioCue> audio;

  /// Null means "inherit the previous frame's camera".
  CameraKey? camera;

  /// How many timeline slots this pose occupies. 1 = normal, 3 = hold 3 slots.
  int hold;

  Map<String, dynamic> toJson() => {
    'id': id,
    'layers': layers.map((l) => l.toJson()).toList(),
    'audio': audio.map((a) => a.toJson()).toList(),
    'camera': camera?.toJson(),
    'hold': hold,
  };

  static Frame fromJson(Map<String, dynamic> j) => Frame(
    id: j['id'] as String? ?? 'frame',
    layers: ((j['layers'] as List?) ?? const [])
        .map((e) => Layer.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    audio: ((j['audio'] as List?) ?? const [])
        .map((e) => AudioCue.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    camera: j['camera'] == null
        ? null
        : CameraKey.fromJson((j['camera'] as Map).cast<String, dynamic>()),
    hold: (j['hold'] as num?)?.toInt() ?? 1,
  );
}

class Background {
  Background({
    this.color = 0xFFFFFFFF,
    this.imageAssetPath,
    this.offset = Vec2.zero,
    this.scale = 1.0,
    this.lockToCamera = true,
    this.dark = false,
  });

  int color;
  String? imageAssetPath;
  Vec2 offset;
  double scale;
  bool lockToCamera;
  bool dark;

  Map<String, dynamic> toJson() => {
    'color': color,
    'img': imageAssetPath,
    'off': offset.toJson(),
    'scale': scale,
    'lockCam': lockToCamera,
    'dark': dark,
  };

  static Background fromJson(Map<String, dynamic> j) => Background(
    color: (j['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
    imageAssetPath: j['img'] as String?,
    offset: Vec2.fromJson(
      (j['off'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    scale: (j['scale'] as num?)?.toDouble() ?? 1.0,
    lockToCamera: j['lockCam'] as bool? ?? true,
    dark: j['dark'] as bool? ?? false,
  );
}

class Sequence {
  Sequence({
    required this.id,
    required this.name,
    List<Frame>? frames,
    this.fps = 12,
    this.loop = true,
    Background? background,
    this.music,
  }) : frames = frames ?? <Frame>[],
       background = background ?? Background();

  String id;
  String name;
  List<Frame> frames;
  int fps;
  bool loop;
  Background background;
  AudioTrack? music;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'frames': frames.map((f) => f.toJson()).toList(),
    'fps': fps,
    'loop': loop,
    'bg': background.toJson(),
    'music': music?.toJson(),
  };

  static Sequence fromJson(Map<String, dynamic> j) => Sequence(
    id: j['id'] as String? ?? 'seq',
    name: (j['name'] as String?) ?? 'Sequence',
    frames: ((j['frames'] as List?) ?? const [])
        .map((e) => Frame.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    fps: (j['fps'] as num?)?.toInt() ?? 12,
    loop: j['loop'] as bool? ?? true,
    background: j['bg'] == null
        ? Background()
        : Background.fromJson((j['bg'] as Map).cast<String, dynamic>()),
    music: j['music'] == null
        ? null
        : AudioTrack.fromJson((j['music'] as Map).cast<String, dynamic>()),
  );
}

/// A reusable sub-animation that can be instanced many times.
class Movieclip {
  Movieclip({required this.id, required this.name, required this.sequence});

  String id;
  String name;
  Sequence sequence;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'seq': sequence.toJson(),
  };

  static Movieclip fromJson(Map<String, dynamic> j) => Movieclip(
    id: j['id'] as String? ?? 'clip',
    name: (j['name'] as String?) ?? 'Clip',
    sequence: Sequence.fromJson(
      (j['seq'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );
}

class Project {
  Project({
    required this.id,
    required this.name,
    List<Sequence>? sequences,
    List<Movieclip>? movieclips,
    this.stageWidth = 480,
    this.stageHeight = 640,
    this.activeSequenceId,
    int? createdAt,
    int? modifiedAt,
    this.schemaVersion = kSchemaVersion,
  }) : sequences = sequences ?? <Sequence>[],
       movieclips = movieclips ?? <Movieclip>[],
       createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
       modifiedAt = modifiedAt ?? DateTime.now().millisecondsSinceEpoch;

  String id;
  String name;
  List<Sequence> sequences;
  List<Movieclip> movieclips;
  double stageWidth;
  double stageHeight;
  String? activeSequenceId;
  int createdAt;
  int modifiedAt;
  int schemaVersion;

  Sequence get activeSequence {
    if (sequences.isEmpty) {
      final s = Sequence(id: 'seq-$id', name: 'Sequence 1');
      sequences.add(s);
      activeSequenceId = s.id;
      return s;
    }
    for (final s in sequences) {
      if (s.id == activeSequenceId) return s;
    }
    return sequences.first;
  }

  Movieclip? clipById(String clipId) {
    for (final c in movieclips) {
      if (c.id == clipId) return c;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'schema': schemaVersion,
    'id': id,
    'name': name,
    'stage': {'w': stageWidth, 'h': stageHeight},
    'sequences': sequences.map((s) => s.toJson()).toList(),
    'movieclips': movieclips.map((c) => c.toJson()).toList(),
    'activeSeq': activeSequenceId,
    'createdAt': createdAt,
    'modifiedAt': modifiedAt,
  };

  static Project fromJson(Map<String, dynamic> j) {
    final stage = (j['stage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final p = Project(
      id: j['id'] as String? ?? 'project',
      name: (j['name'] as String?) ?? 'Untitled',
      sequences: ((j['sequences'] as List?) ?? const [])
          .map((e) => Sequence.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      movieclips: ((j['movieclips'] as List?) ?? const [])
          .map((e) => Movieclip.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      stageWidth: (stage['w'] as num?)?.toDouble() ?? 480,
      stageHeight: (stage['h'] as num?)?.toDouble() ?? 640,
      activeSequenceId: j['activeSeq'] as String?,
      createdAt: (j['createdAt'] as num?)?.toInt(),
      modifiedAt: (j['modifiedAt'] as num?)?.toInt(),
      schemaVersion: (j['schema'] as num?)?.toInt() ?? 1,
    );
    return p;
  }
}
