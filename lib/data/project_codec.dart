import 'dart:convert';

import 'geometry.dart';
import 'models.dart';

/// Serialises a [Project] to JSON and back.
///
/// The format is deliberately plain and hand-readable: when a user reports
/// "my animation opened blank", being able to open project.json in a text
/// editor is worth more than saving a few kilobytes.
class ProjectCodec {
  ProjectCodec._();

  /// Pretty-printed output would triple the file size for no real benefit, but
  /// one newline at the end keeps `cat` / git happy.
  static String encode(Project project) {
    final payload = project.toJson();
    payload['app'] = 'stickscene';
    return '${const JsonEncoder.withIndent('  ').convert(payload)}\n';
  }

  /// Throws [FormatException] on malformed input rather than silently
  /// returning an empty project - a loud failure is what the recovery path in
  /// [ProjectRepository] needs in order to fall back to a backup.
  static Project decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('project root is not a JSON object');
    }
    final json = decoded.cast<String, dynamic>();
    final project = Project.fromJson(json);
    return _migrate(project, (json['schema'] as num?)?.toInt() ?? 1);
  }

  static Project _migrate(Project p, int fromVersion) {
    var project = p;
    if (fromVersion < 2) {
      project = _v1ToV2(project);
    }
    return project;
  }

  /// Schema 1 -> 2: v1 had no per-frame camera, no audio cues and no hold
  /// values. Those default cleanly, so this only needs to stamp the version.
  static Project _v1ToV2(Project p) {
    for (final seq in p.sequences) {
      for (final frame in seq.frames) {
        frame.hold = frame.hold < 1 ? 1 : frame.hold;
        frame.camera ??= CameraKey.defaultCamera;
        if (frame.audio.isEmpty && seq.music == null) {
          // nothing to do; audio simply did not exist in v1
        }
      }
    }
    p.schemaVersion = 2;
    return p;
  }

  /// Reads just enough of the file to draw the project card in the library,
  /// without decoding every frame.
  static ProjectSummary peekSummary(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('project root is not a JSON object');
    }
    final j = decoded.cast<String, dynamic>();
    final seqs = (j['sequences'] as List?) ?? const [];
    int frameCount = 0;
    int maxFps = 0;
    for (final s in seqs) {
      final sm = (s as Map).cast<String, dynamic>();
      final n = (sm['frames'] as List?)?.length ?? 0;
      frameCount += n;
      final fps = (sm['fps'] as num?)?.toInt() ?? 0;
      if (fps > maxFps) maxFps = fps;
    }
    final stage = (j['stage'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ProjectSummary(
      id: j['id'] as String? ?? '',
      name: (j['name'] as String?) ?? 'Untitled',
      sequenceCount: seqs.length,
      frameCount: frameCount,
      fps: maxFps,
      width: (stage['w'] as num?)?.toDouble() ?? 0,
      height: (stage['h'] as num?)?.toDouble() ?? 0,
      modifiedAt: (j['modifiedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.sequenceCount,
    required this.frameCount,
    required this.fps,
    required this.width,
    required this.height,
    required this.modifiedAt,
  });

  final String id;
  final String name;
  final int sequenceCount;
  final int frameCount;
  final int fps;
  final double width;
  final double height;
  final int modifiedAt;
}

/// Small helper used by the renderer for stable colour maths without dragging
/// all of `dart:ui` into the data layer.
int withOpacityOn(int argb, double opacity) {
  final a = ((argb >> 24) & 0xFF);
  final newA = (clampDouble(a * opacity, 0, 255)).round();
  return (newA << 24) | (argb & 0x00FFFFFF);
}

int mixColor(int a, int b, double t) {
  t = clampDouble(t, 0, 1);
  int ch(int shift) {
    final av = (a >> shift) & 0xFF;
    final bv = (b >> shift) & 0xFF;
    return (av + (bv - av) * t).round() & 0xFF;
  }

  return (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
}
