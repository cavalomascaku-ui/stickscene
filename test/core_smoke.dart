// Standalone verification harness.
//
// Run with:  dart run test/core_smoke.dart
// It imports the model layer by relative path, so it needs no pub get and runs
// on a bare Dart VM. Every check is an assert on real behaviour: the goal is to
// catch "it compiled but the maths is wrong" before this ever reaches a phone.

import 'dart:convert';

import '../lib/data/geometry.dart';
import '../lib/data/models.dart';
import '../lib/data/project_codec.dart';
import '../lib/editor/interpolation.dart';
import '../lib/editor/stick_rigs.dart';

int _failures = 0;
int _checks = 0;

void check(String label, bool ok) {
  _checks++;
  if (!ok) {
    _failures++;
    print('  FAIL  $label');
  } else {
    print('  ok    $label');
  }
}

bool closeTo(double a, double b, [double tol = 1e-6]) => (a - b).abs() <= tol;

void main() {
  print('\n--- geometry ---');
  check(
    'lerp endpoints',
    Vec2.lerp(const Vec2(0, 0), const Vec2(10, 20), 0).x == 0,
  );
  check(
    'lerp midpoint',
    closeTo(Vec2.lerp(const Vec2(0, 0), const Vec2(10, 20), 0.5).y, 10),
  );
  check(
    'lerp clamps past 1',
    Vec2.lerp(const Vec2(0, 0), const Vec2(4, 4), 2).x == 4,
  );
  check(
    'rotation 90deg',
    closeTo(const Vec2(1, 0).rotated(1.5707963267948966).y, 1),
  );
  check('length', closeTo(const Vec2(3, 4).length, 5));
  check('normalized', closeTo(const Vec2(0, -5).normalized.y, -1));

  print('\n--- transform compose ---');
  // Semantics: `a.compose(b)` means "apply a, then b on top of it".
  final parent = Transform2D(translation: const Vec2(10, 0), scale: 2);
  final child = Transform2D(translation: const Vec2(1, 0));

  // parent first (x moves to 10, then child adds 1*2 because the parent already
  // doubled everything) -> 11
  final parentThenChild = parent.compose(child);
  check('compose scale multiplies', closeTo(parentThenChild.scale, 2));
  check(
    'compose parent-then-child translation',
    closeTo(parentThenChild.translation.x, 11),
  );

  // child first (x moves to 1, then parent scales it by 2 and adds 10) -> 12
  final childThenParent = child.compose(parent);
  check(
    'compose child-then-parent translation',
    closeTo(childThenParent.translation.x, 12),
  );
  check(
    'composed translation equals applying both by hand',
    closeTo(
      childThenParent.translation.x,
      parent.applyLocal(child.translation).x,
      1e-9,
    ),
  );
  check(
    'composed maps a point identically to nested application',
    closeTo(
      childThenParent.applyLocal(const Vec2(0, 0)).x,
      parent.applyLocal(child.applyLocal(const Vec2(0, 0))).x,
      1e-9,
    ),
  );

  print('\n--- camera interpolation takes the short way ---');
  // The interpolator must always take the arc of at most pi. Feeding it
  // rotation pairs that straddle the 2pi seam is exactly where a naive
  // implementation spins the camera the long way round.
  final pairs = <List<double>>[
    [3.0, 0.2], // 172 deg -> 11 deg  (short way is backwards, -2.8)
    [0.1, 6.2], // 6 deg  -> 355 deg (short way is forwards, +6.1 - tau)
    [-3.0, 3.0], // seam crossing
    [0.0, 0.0],
  ];
  var allShort = true;
  for (final pair in pairs) {
    final mid = CameraKey(rotation: pair[0])
        .interpolated(CameraKey(rotation: pair[1]), 0.5);
    var delta = mid.rotation - pair[0];
    const tau = 6.283185307179586;
    while (delta > 3.141592653589793) delta -= tau;
    while (delta < -3.141592653589793) delta += tau;
    if (delta.abs() > 3.141592653589793 + 1e-9) allShort = false;
  }
  check('rotation always takes the short arc', allShort);

  print('\n--- figures ---');
  final standing = StickRigs.standing();
  check('standing has bones', standing.bones.length == 10);
  check('standing has anchors', standing.anchors.length == 15);
  // Every bone must have been resolved to real coordinates, not left at origin.
  final spine = standing.bones.firstWhere((b) => b.name == 'spine');
  check('spine resolved', !spine.a.x.isNaN && spine.a != Vec2.zero);
  check(
    'all bones resolve to anchors',
    standing.bones.every((b) => b.a != Vec2.zero || b.b != Vec2.zero),
  );

  final walkPose = StickRigs.walking();
  check(
    'walking differs from idle',
    walkPose.anchors[Anchor.footL] != standing.anchors[Anchor.footL],
  );

  print('\n--- tween between poses (the core feature) ---');
  // Mirror what the editor really does: insert a frame (which copies the
  // object, id and all) and then drag anchors on the copy.
  final walk = standing.duplicate(standing.id);
  walk.anchors = Map<Anchor, Vec2>.from(walkPose.anchors);
  // Editing anchors must be followed by a bone resolve, exactly like the
  // editor does; otherwise the bones would still point at the old pose.
  final walkResolved = StickRigs.resolveBones(walk);

  final seq = Sequence(id: 's', name: 'test');
  final f1 = Frame(id: 'f1');
  f1.layers.add(Layer(id: 'l1', name: 'L', objects: [standing]));
  final f2 = Frame(id: 'f2');
  f2.layers.add(Layer(id: 'l1', name: 'L', objects: [walkResolved]));
  seq.frames.addAll([f1, f2]);

  final half = resolveScene(seq, 0.5);
  check('tween resolves to one layer', half.layers.length == 1);
  final tweenObjects = half.layers.first.objects;
  check('tween has the figure', tweenObjects.length == 1);
  final tweened = tweenObjects.first as FigureObject;

  final standFoot = standing.anchors[Anchor.footL]!;
  final walkFoot = walkResolved.anchors[Anchor.footL]!;
  final midFoot = tweened.anchors[Anchor.footL]!;
  check(
    'anchor is exactly halfway',
    closeTo(midFoot.x, (standFoot.x + walkFoot.x) / 2, 1e-9) &&
        closeTo(midFoot.y, (standFoot.y + walkFoot.y) / 2, 1e-9),
  );
  check(
    'tweened figure is genuinely between poses',
    (midFoot.x - standFoot.x).abs() > 0.5,
  );

  // Bones must follow the interpolated anchors, not stay at the source pose.
  final shinA = tweened.bones.firstWhere((b) => b.name == 'shinL');
  check(
    'bone follows interpolated anchor',
    shinA.b.x != standing.bones.firstWhere((b) => b.name == 'shinL').b.x,
  );

  print('\n--- resolve at integer frames is exact ---');
  final exact = resolveScene(seq, 0.0);
  final exactObj = exact.layers.first.objects.first as FigureObject;
  check(
    'frame 0 returns the source pose',
    closeTo(exactObj.anchors[Anchor.footL]!.x, standFoot.x, 1e-9),
  );

  print('\n--- objects with different ids cross-fade, not vanish ---');
  final seqX = Sequence(id: 'sx', name: 'x');
  final x1 = Frame(id: 'x1');
  x1.layers.add(Layer(id: 'l', name: 'L', objects: [StickRigs.standing()]));
  final x2 = Frame(id: 'x2');
  x2.layers.add(Layer(id: 'l', name: 'L', objects: [StickRigs.standing()]));
  seqX.frames.addAll([x1, x2]);
  final cross = resolveScene(seqX, 0.5).layers.first.objects;
  check('both ids present mid-fade', cross.length == 2);
  check(
    'both at half opacity',
    cross.every((o) => (o.opacity - 0.5).abs() < 1e-9),
  );

  print('\n--- layer fade in/out ---');
  final seq2 = Sequence(id: 's2', name: 't');
  final g1 = Frame(id: 'g1');
  g1.layers.add(
    Layer(
      id: 'l',
      name: 'L',
      objects: [CircleObject(id: 'c', center: Vec2.zero)],
    ),
  );
  final g2 = Frame(id: 'g2');
  g2.layers.add(Layer(id: 'l', name: 'L'));
  seq2.frames.addAll([g1, g2]);
  final fade = resolveScene(seq2, 0.5).layers.first.objects.first;
  check(
    'object fading out keeps half opacity',
    closeTo(fade.opacity, 0.5, 1e-9),
  );

  print('\n--- movieclip expansion ---');
  final clipSeq = Sequence(id: 'cs', name: 'clip');
  final cf = Frame(id: 'cf');
  cf.layers.add(
    Layer(
      id: 'cl',
      name: 'L',
      objects: [StickRigs.standing(at: Vec2.zero)],
    ),
  );
  clipSeq.frames.add(cf);
  final project = Project(id: 'p', name: 'P');
  project.movieclips.add(
    Movieclip(id: 'clip1', name: 'clip', sequence: clipSeq),
  );

  final hostSeq = Sequence(id: 'hs', name: 'host');
  final hf = Frame(id: 'hf');
  hf.layers.add(
    Layer(
      id: 'hl',
      name: 'L',
      objects: [MovieclipObject(id: 'mo', clipId: 'clip1', lengthFrames: 24)],
    ),
  );
  hostSeq.frames.add(hf);

  final expanded = expandMovieclips(
    hf.layers.first.objects,
    (id) => project.clipById(id)?.sequence,
    0.0,
    0,
  );
  check(
    'movieclip expanded to the figure',
    expanded.length == 1 && expanded.first is FigureObject,
  );

  print('\n--- codec round trip ---');
  final p = Project(id: 'p1', name: 'Meu Projeto');
  p.stageWidth = 400;
  p.sequences.add(seq);
  final encoded = ProjectCodec.encode(p);
  final decoded = ProjectCodec.decode(encoded);
  check('round trip name', decoded.name == 'Meu Projeto');
  check('round trip stage', closeTo(decoded.stageWidth, 400));
  check('round trip sequence count', decoded.sequences.length == 1);
  check('round trip frame count', decoded.sequences.first.frames.length == 2);
  final backFig =
      decoded.sequences.first.frames.first.layers.first.objects.first;
  check('round trip keeps figure type', backFig is FigureObject);
  check(
    'round trip keeps anchors',
    (backFig as FigureObject).anchors.length == 15,
  );

  print('\n--- schema migration ---');
  final oldJson =
      '{"schema":1,"id":"x","name":"antigo","sequences":['
      '{"id":"s","name":"S","fps":8,"frames":[{"id":"f","layers":[]}]}],'
      '"stage":{"w":480,"h":640}}';
  final migrated = ProjectCodec.decode(oldJson);
  check('v1 migrated to v2', migrated.schemaVersion == 2);
  check(
    'v1 frame got a camera',
    migrated.sequences.first.frames.first.camera != null,
  );

  print('\n--- summary peek ---');
  final summary = ProjectCodec.peekSummary(encoded);
  check('summary counts frames', summary.frameCount == 2);
  check('summary counts sequences', summary.sequenceCount == 1);

  print('\n--- unknown object kind survives ---');
  // A file written by a newer build must not crash an older one.
  final futureJson = jsonDecode(
    '{"id":"z","kind":"holo_hologram","t":{"translation":{"x":1,"y":2},'
    '"rotation":0,"scale":1},"v":true}',
  ) as Map<String, dynamic>;
  final recovered = sceneObjectFromJson(futureJson);
  check('unknown kind decodes to a visible placeholder', recovered.visible);
  check('unknown kind keeps its id', recovered.id == 'z');
  check(
    'unknown kind lands on the current frame',
    recovered.transform.translation.x == 1,
  );

  print('\n--- broken files are rejected loudly ---');
  var threw = false;
  try {
    ProjectCodec.decode('this is not json');
  } on FormatException {
    threw = true;
  }
  check('malformed json throws FormatException', threw);

  print('\n=====================================');
  print('checks: $_checks   failures: $_failures');
  print('=====================================');
  if (_failures > 0) {
    throw StateError('$_failures check(s) failed');
  }
}
