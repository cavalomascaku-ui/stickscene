import '../data/geometry.dart';
import '../data/models.dart';
import '../core/ids.dart';

/// Built-in stick figure rigs and poses.
///
/// Nothing here is derived from any third-party artwork - a stick figure is
/// literally a handful of line segments and a circle, so the classic look is
/// reproduced by getting the proportions and the stroke weight right.
///
/// Convention: the figure's origin sits at the hip, +Y points DOWN (screen
/// space), so "hip to head" is a negative Y. A standing figure is ~190 units
/// tall, which reads well on the 480x640 default stage.
class StickRigs {
  StickRigs._();

  static const double defaultThickness = 9;
  static const int defaultColor = 0xFF14161A;
  static const double headRadius = 13;

  /// Neutral anchor layout shared by every standing pose. Individual poses
  /// override the entries they move.
  static Map<Anchor, Vec2> _standing() => {
    Anchor.head: const Vec2(0, -86),
    Anchor.neck: const Vec2(0, -68),
    Anchor.chest: const Vec2(0, -62),
    Anchor.shoulderL: const Vec2(-14, -62),
    Anchor.shoulderR: const Vec2(14, -62),
    Anchor.elbowL: const Vec2(-26, -42),
    Anchor.elbowR: const Vec2(26, -42),
    Anchor.handL: const Vec2(-30, -20),
    Anchor.handR: const Vec2(30, -20),
    Anchor.waist: const Vec2(0, -32),
    Anchor.hip: const Vec2(0, 0),
    Anchor.kneeL: const Vec2(-15, 42),
    Anchor.kneeR: const Vec2(15, 42),
    Anchor.footL: const Vec2(-17, 84),
    Anchor.footR: const Vec2(17, 84),
  };

  /// The bone table. Each limb is drawn from anchor to anchor, which is what
  /// makes tweening between poses work: only the anchors move.
  static List<Bone> _skeleton() {
    List<Bone> b(BoneName n, Anchor a, Anchor c, {double? t}) => [
      Bone(
        name: n.name,
        a: Vec2.zero,
        b: Vec2.zero,
        thickness: t ?? defaultThickness,
        anchorA: a,
        anchorB: c,
      ),
    ];
    return [
      ...b(BoneName.spine, Anchor.neck, Anchor.hip),
      ...b(BoneName.shoulderBar, Anchor.shoulderL, Anchor.shoulderR, t: 7),
      ...b(BoneName.upperArmL, Anchor.shoulderL, Anchor.elbowL),
      ...b(BoneName.upperArmR, Anchor.shoulderR, Anchor.elbowR),
      ...b(BoneName.foreArmL, Anchor.elbowL, Anchor.handL),
      ...b(BoneName.foreArmR, Anchor.elbowR, Anchor.handR),
      ...b(BoneName.thighL, Anchor.hip, Anchor.kneeL),
      ...b(BoneName.thighR, Anchor.hip, Anchor.kneeR),
      ...b(BoneName.shinL, Anchor.kneeL, Anchor.footL),
      ...b(BoneName.shinR, Anchor.kneeR, Anchor.footR),
    ];
  }

  static List<Joint> _joints(Map<Anchor, Vec2> a, {bool showAll = false}) {
    if (!showAll) return const [];
    return [
      Joint(name: 'head', p: _center(a, Anchor.head), radius: headRadius),
      Joint(name: 'hip', p: a[Anchor.hip]!, radius: 4),
      Joint(name: 'handL', p: a[Anchor.handL]!, radius: 3),
      Joint(name: 'handR', p: a[Anchor.handR]!, radius: 3),
      Joint(name: 'footL', p: a[Anchor.footL]!, radius: 3),
      Joint(name: 'footR', p: a[Anchor.footR]!, radius: 3),
    ];
  }

  /// Head is drawn as a circle centred slightly above the head anchor so the
  /// neck connects to the underside of the head, not its centre.
  static Vec2 _center(Map<Anchor, Vec2> a, Anchor k) {
    final p = a[k]!;
    return Vec2(p.x, p.y - headRadius * 0.55);
  }

  static FigureObject _figure(
    Map<Anchor, Vec2> anchors, {
    String name = 'Figure',
    int color = defaultColor,
    double thickness = defaultThickness,
    bool showJoints = false,
    Vec2? position,
  }) {
    final fig = FigureObject(
      id: IdGen.next('fig'),
      name: name,
      bones: _skeleton(),
      anchors: anchors,
      joints: _joints(anchors, showAll: showJoints),
      thickness: thickness,
      color: color,
      showJoints: showJoints,
      transform: Transform2D(translation: position ?? Vec2.zero),
    );
    return resolveBones(fig);
  }

  /// Fills each bone's `a`/`b` from its anchors. Called after any anchor edit.
  static FigureObject resolveBones(FigureObject fig) => resolveFigure(fig);

  // -------------------------------------------------------------------------
  // Poses
  // -------------------------------------------------------------------------

  static FigureObject standing({Vec2? at}) =>
      _figure(_standing(), name: 'Idle', position: at);

  static FigureObject walking({Vec2? at}) {
    final a = _standing();
    a[Anchor.kneeL] = const Vec2(-16, 42);
    a[Anchor.footL] = const Vec2(-30, 84);
    a[Anchor.kneeR] = const Vec2(16, 42);
    a[Anchor.footR] = const Vec2(28, 84);
    a[Anchor.handL] = const Vec2(24, -20);
    a[Anchor.handR] = const Vec2(-24, -20);
    a[Anchor.waist] = const Vec2(0, -32);
    return _figure(a, name: 'Walk', position: at);
  }

  static FigureObject running({Vec2? at}) {
    final a = _standing();
    a[Anchor.neck] = const Vec2(4, -68);
    a[Anchor.chest] = const Vec2(3, -62);
    a[Anchor.shoulderL] = const Vec2(-9, -62);
    a[Anchor.shoulderR] = const Vec2(17, -62);
    a[Anchor.elbowL] = const Vec2(-26, -46);
    a[Anchor.elbowR] = const Vec2(30, -50);
    a[Anchor.handL] = const Vec2(-18, -66);
    a[Anchor.handR] = const Vec2(38, -68);
    a[Anchor.hip] = const Vec2(0, 0);
    a[Anchor.kneeL] = const Vec2(-22, 38);
    a[Anchor.kneeR] = const Vec2(18, 44);
    a[Anchor.footL] = const Vec2(-8, 80);
    a[Anchor.footR] = const Vec2(46, 62);
    return _figure(a, name: 'Run', position: at);
  }

  static FigureObject punching({Vec2? at, bool rightHand = true}) {
    final a = _standing();
    if (rightHand) {
      a[Anchor.elbowR] = const Vec2(30, -58);
      a[Anchor.handR] = const Vec2(54, -60);
      a[Anchor.elbowL] = const Vec2(-22, -40);
      a[Anchor.handL] = const Vec2(-14, -20);
      a[Anchor.footL] = const Vec2(-30, 84);
      a[Anchor.footR] = const Vec2(24, 84);
    } else {
      a[Anchor.elbowL] = const Vec2(-30, -58);
      a[Anchor.handL] = const Vec2(-54, -60);
      a[Anchor.elbowR] = const Vec2(22, -40);
      a[Anchor.handR] = const Vec2(14, -20);
      a[Anchor.footL] = const Vec2(-24, 84);
      a[Anchor.footR] = const Vec2(30, 84);
    }
    return _figure(a, name: 'Punch', position: at);
  }

  static FigureObject kicking({Vec2? at, bool rightLeg = true}) {
    final a = _standing();
    if (rightLeg) {
      a[Anchor.kneeR] = const Vec2(24, 34);
      a[Anchor.footR] = const Vec2(52, 8);
      a[Anchor.kneeL] = const Vec2(-14, 42);
      a[Anchor.footL] = const Vec2(-20, 84);
    } else {
      a[Anchor.kneeL] = const Vec2(-24, 34);
      a[Anchor.footL] = const Vec2(-52, 8);
      a[Anchor.kneeR] = const Vec2(14, 42);
      a[Anchor.footR] = const Vec2(20, 84);
    }
    a[Anchor.elbowL] = const Vec2(-30, -48);
    a[Anchor.handL] = const Vec2(-36, -30);
    a[Anchor.elbowR] = const Vec2(30, -48);
    a[Anchor.handR] = const Vec2(36, -30);
    return _figure(a, name: 'Kick', position: at);
  }

  static FigureObject jumping({Vec2? at}) {
    final a = _standing();
    a[Anchor.kneeL] = const Vec2(-20, 34);
    a[Anchor.footL] = const Vec2(-28, 68);
    a[Anchor.kneeR] = const Vec2(20, 34);
    a[Anchor.footR] = const Vec2(28, 68);
    a[Anchor.elbowL] = const Vec2(-34, -74);
    a[Anchor.handL] = const Vec2(-42, -92);
    a[Anchor.elbowR] = const Vec2(34, -74);
    a[Anchor.handR] = const Vec2(42, -92);
    return _figure(a, name: 'Jump', position: at);
  }

  static FigureObject falling({Vec2? at}) {
    final a = _standing();
    a[Anchor.elbowL] = const Vec2(-36, -70);
    a[Anchor.handL] = const Vec2(-48, -86);
    a[Anchor.elbowR] = const Vec2(36, -70);
    a[Anchor.handR] = const Vec2(48, -86);
    a[Anchor.kneeL] = const Vec2(-22, 36);
    a[Anchor.footL] = const Vec2(-34, 60);
    a[Anchor.kneeR] = const Vec2(20, 40);
    a[Anchor.footR] = const Vec2(32, 66);
    return _figure(a, name: 'Fall', position: at);
  }

  static FigureObject sitting({Vec2? at}) {
    final a = _standing();
    a[Anchor.neck] = const Vec2(-4, -56);
    a[Anchor.chest] = const Vec2(-4, -50);
    a[Anchor.shoulderL] = const Vec2(-18, -50);
    a[Anchor.shoulderR] = const Vec2(10, -50);
    a[Anchor.waist] = const Vec2(-2, -24);
    a[Anchor.hip] = const Vec2(0, 0);
    a[Anchor.kneeL] = const Vec2(26, 6);
    a[Anchor.kneeR] = const Vec2(28, 8);
    a[Anchor.footL] = const Vec2(28, 48);
    a[Anchor.footR] = const Vec2(30, 50);
    a[Anchor.elbowL] = const Vec2(-16, -32);
    a[Anchor.handL] = const Vec2(-6, -18);
    a[Anchor.elbowR] = const Vec2(24, -34);
    a[Anchor.handR] = const Vec2(34, -20);
    return _figure(a, name: 'Sit', position: at);
  }

  static FigureObject lying({Vec2? at}) {
    final a = _standing();
    a[Anchor.neck] = const Vec2(-70, 0);
    a[Anchor.chest] = const Vec2(-64, 0);
    a[Anchor.shoulderL] = const Vec2(-60, -10);
    a[Anchor.shoulderR] = const Vec2(-60, 10);
    a[Anchor.waist] = const Vec2(-32, 0);
    a[Anchor.hip] = const Vec2(-28, 0);
    a[Anchor.kneeL] = const Vec2(8, 8);
    a[Anchor.kneeR] = const Vec2(8, -8);
    a[Anchor.footL] = const Vec2(44, 6);
    a[Anchor.footR] = const Vec2(44, -6);
    a[Anchor.elbowL] = const Vec2(-52, -24);
    a[Anchor.handL] = const Vec2(-28, -30);
    a[Anchor.elbowR] = const Vec2(-52, 24);
    a[Anchor.handR] = const Vec2(-28, 30);
    return _figure(a, name: 'Lie', position: at);
  }

  /// The palette offered in the figure editor. Deliberately cohesive: every
  /// entry reads clearly against the default white stage.
  static const List<int> palette = [
    0xFF14161A, // ink
    0xFF3B82F6, // blue
    0xFFEF4444, // red
    0xFFF59E0B, // amber
    0xFF10B981, // green
    0xFF8B5CF6, // violet
    0xFFEC4899, // pink
    0xFF0EA5E9, // sky
    0xFF6B7280, // slate
    0xFF92400E, // brown
  ];
}

enum BoneName {
  spine,
  shoulderBar,
  upperArmL,
  upperArmR,
  foreArmL,
  foreArmR,
  thighL,
  thighR,
  shinL,
  shinR,
}

/// Names shown in the bone list UI.
const Map<BoneName, String> boneLabels = {
  BoneName.spine: 'Torso',
  BoneName.shoulderBar: 'Ombros',
  BoneName.upperArmL: 'Braço esq.',
  BoneName.upperArmR: 'Braço dir.',
  BoneName.foreArmL: 'Antebraço esq.',
  BoneName.foreArmR: 'Antebraço dir.',
  BoneName.thighL: 'Coxa esq.',
  BoneName.thighR: 'Coxa dir.',
  BoneName.shinL: 'Panturrilha esq.',
  BoneName.shinR: 'Panturrilha dir.',
};

const Map<Anchor, String> anchorLabels = {
  Anchor.head: 'Cabeça',
  Anchor.neck: 'Pescoço',
  Anchor.chest: 'Peito',
  Anchor.hip: 'Quadril',
  Anchor.waist: 'Cintura',
  Anchor.shoulderL: 'Ombro esq.',
  Anchor.shoulderR: 'Ombro dir.',
  Anchor.elbowL: 'Cotovelo esq.',
  Anchor.elbowR: 'Cotovelo dir.',
  Anchor.handL: 'Mão esq.',
  Anchor.handR: 'Mão dir.',
  Anchor.kneeL: 'Joelho esq.',
  Anchor.kneeR: 'Joelho dir.',
  Anchor.footL: 'Pé esq.',
  Anchor.footR: 'Pé dir.',
};
