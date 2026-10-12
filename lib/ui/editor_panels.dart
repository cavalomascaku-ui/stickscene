import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/geometry.dart';
import '../data/models.dart';
import '../data/project_repository.dart';
import '../editor/editor_controller.dart';
import '../editor/stick_rigs.dart';
import '../export/exporter.dart';
import '../export/video_export.dart';
import '../l10n/strings.dart';

import 'package:provider/provider.dart';

/// Sheet bodies. Kept out of the editor screen file so the gesture code stays
/// readable; every entry point is a plain function so the editor just calls
/// `showXSheet(context, controller)`.

void _open(BuildContext context, Widget child) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => child,
  );
}

Widget _Sheet({
  required String title,
  required Widget child,
  Widget? trailing,
}) {
  return SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
        Flexible(child: child),
        const SizedBox(height: 12),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Poses
// ---------------------------------------------------------------------------

FigureObject Function() _poseFor(String key) => switch (key) {
  'walk' => StickRigs.walking,
  'run' => StickRigs.running,
  'punch' => StickRigs.punching,
  'kick' => StickRigs.kicking,
  'jump' => StickRigs.jumping,
  'fall' => StickRigs.falling,
  'sit' => StickRigs.sitting,
  'lie' => StickRigs.lying,
  _ => StickRigs.standing,
};

void showPoseSheet(
  BuildContext context,
  EditorController c,
  String Function(String) newId,
) {
  final s = Strings.of(context);
  final poses = <String, String>{
    'stand': s.t('poseStand'),
    'walk': s.t('poseWalk'),
    'run': s.t('poseRun'),
    'punch': s.t('posePunch'),
    'kick': s.t('poseKick'),
    'jump': s.t('poseJump'),
    'fall': s.t('poseFall'),
    'sit': s.t('poseSit'),
    'lie': s.t('poseLie'),
  };

  _open(
    context,
    _Sheet(
      title: s.t('pose'),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final entry in poses.entries)
            ListTile(
              leading: const Icon(Icons.accessibility_new_rounded),
              title: Text(entry.value),
              onTap: () {
                Navigator.pop(context);
                // Keep the figure's position and identity, only swap the pose:
                // that is what lets the tweener match it across frames.
                final fig = _poseFor(entry.key)();
                final selected = c.selectedObject;
                if (selected is FigureObject) {
                  c.mutate(() {
                    final anchors = Map<Anchor, Vec2>.from(fig.anchors);
                    c.updateFigureAnchors(selected.copy(selected.id), anchors);
                  });
                } else {
                  c.addFigure(fig);
                }
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Layers + groups
// ---------------------------------------------------------------------------

void showLayerSheet(
  BuildContext context,
  EditorController c,
  String Function(String) newId,
) {
  _open(
    context,
    StatefulBuilder(
      builder: (ctx, setSheetState) => _Sheet(
        title: Strings.of(ctx).t('layers'),
        trailing: IconButton(
          icon: const Icon(Icons.add_rounded),
          tooltip: Strings.of(ctx).t('addLayer'),
          onPressed: () {
            c.addLayer();
            setSheetState(() {});
          },
        ),
        child: () {
          final layers = c.frame.layers;
          if (layers.isEmpty) {
            return Center(child: Text(Strings.of(ctx).t('noSounds')));
          }
          // Children first so parents can indent them.
          final ordered = <Layer>[];
          void walk(String? parentId, int depth) {
            for (final l in layers.where((e) => e.parentId == parentId)) {
              ordered.add(l);
              walk(l.id, depth + 1);
            }
          }

          walk(null, 0);

          return ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: ordered.length,
            itemBuilder: (context, i) {
              final l = ordered[i];
              final locked = c.isLayerLocked(l.id);
              final isGroup = layers.any((e) => e.parentId == l.id);
              return Padding(
                padding: EdgeInsets.only(
                  left: (l.parentId == null ? 0 : 20).toDouble(),
                ),
                child: ListTile(
                  dense: true,
                  selected: c.selectedLayerId == l.id,
                  leading: Icon(
                    isGroup
                        ? Icons.folder_rounded
                        : (l.objects.isEmpty
                              ? Icons.layers_clear_rounded
                              : Icons.layers_rounded),
                  ),
                  title: Text(l.name),
                  subtitle: Text('${l.objects.length} obj'),
                  onTap: () {
                    c.selectedLayerId = l.id;
                    setSheetState(() {});
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          l.visible
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                        onPressed: () {
                          c.mutate(() => l.visible = !l.visible);
                          setSheetState(() {});
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                        ),
                        onPressed: () {
                          c.mutate(() => l.locked = !l.locked);
                          setSheetState(() {});
                        },
                      ),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          switch (v) {
                            case 'group':
                              c.groupLayer(l.id);
                            case 'ungroup':
                              c.ungroupLayer(l.id);
                            case 'delete':
                              c.deleteLayer(l.id);
                          }
                          setSheetState(() {});
                        },
                        itemBuilder: (_) => [
                          if (!isGroup)
                            const PopupMenuItem(
                              value: 'group',
                              child: Text('Agrupar'),
                            ),
                          if (isGroup)
                            const PopupMenuItem(
                              value: 'ungroup',
                              child: Text('Desagrupar'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Excluir'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        }(),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Camera / v-cam
// ---------------------------------------------------------------------------

void showCameraSheet(BuildContext context, EditorController c) {
  _open(
    context,
    StatefulBuilder(
      builder: (ctx, setSheetState) {
        final cam = c.currentCamera;
        void update(CameraKey next) {
          c.setCamera(next);
          setSheetState(() {});
        }

        return _Sheet(
          title: Strings.of(ctx).t('camera'),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _slider(
                    ctx,
                    Strings.of(ctx).t('cameraZoom'),
                    cam.zoom,
                    0.2,
                    6,
                    (v) => update(cam.copyWith(zoom: v)),
                  ),
                  _slider(
                    ctx,
                    Strings.of(ctx).t('cameraRotate'),
                    cam.rotation,
                    -3.14,
                    3.14,
                    (v) => update(cam.copyWith(rotation: v)),
                  ),
                  _slider(
                    ctx,
                    '${Strings.of(ctx).t('cameraCenter')} X',
                    cam.center.x,
                    -600,
                    600,
                    (v) => update(cam.copyWith(center: Vec2(v, cam.center.y))),
                  ),
                  _slider(
                    ctx,
                    '${Strings.of(ctx).t('cameraCenter')} Y',
                    cam.center.y,
                    -600,
                    600,
                    (v) => update(cam.copyWith(center: Vec2(cam.center.x, v))),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => update(CameraKey()),
                          icon: const Icon(Icons.restart_alt_rounded),
                          label: Text(Strings.of(ctx).t('cameraReset')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => update(
                            cam.copyWith(
                              center: Vec2(0, 0),
                              zoom: 1,
                              rotation: 0,
                            ),
                          ),
                          icon: const Icon(Icons.done_all_rounded),
                          label: Text(Strings.of(ctx).t('cameraApplyAll')),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () {
                      c.clearCameraKeyframe();
                      setSheetState(() {});
                    },
                    icon: const Icon(Icons.key_rounded),
                    label: Text(Strings.of(ctx).t('cameraClearKey')),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

Widget _slider(
  BuildContext context,
  String label,
  double value,
  double min,
  double max,
  ValueChanged<double> onChanged,
) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            value.toStringAsFixed(2),
            style: TextStyle(color: paletteOf(context).textDim),
          ),
        ],
      ),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Audio
// ---------------------------------------------------------------------------

const _audioExtensions = ['mp3', 'wav', 'ogg', 'm4a', 'aac', 'flac'];

void showAudioSheet(BuildContext context, EditorController c) {
  final s = Strings.of(context);
  _open(
    context,
    StatefulBuilder(
      builder: (ctx, setSheetState) => _Sheet(
        title: s.t('audio'),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.library_music_rounded),
              title: Text(s.t('addSound')),
              subtitle: Text(s.t('noSounds')),
              onTap: () async {
                final repo = context.read<ProjectRepository>();
                final picked = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: _audioExtensions,
                );
                if (picked == null || picked.files.isEmpty) return;
                final path = picked.files.first.path;
                if (path == null) return;
                final bytes = await File(path).length();
                final relative = await repo.importMedia(
                  c.project,
                  File(path),
                  '.${path.split('.').last}',
                );
                final abs = await repo.resolveMedia(c.project, relative);
                c.addAudioCue(
                  AudioCue(
                    id: 'cue-${DateTime.now().millisecondsSinceEpoch}',
                    assetPath: abs.path,
                    startFrame: 0,
                    volume: 1,
                    durationSeconds: bytes / 128000,
                  ),
                );
                setSheetState(() {});
              },
            ),
            ListTile(
              leading: const Icon(Icons.music_note_rounded),
              title: Text(s.t('addMusic')),
              trailing: c.sequence.music == null
                  ? null
                  : Switch(
                      value: c.sequence.music!.enabled,
                      onChanged: (v) {
                        c.mutate(() => c.sequence.music!.enabled = v);
                        setSheetState(() {});
                      },
                    ),
              onTap: () async {
                final repo = context.read<ProjectRepository>();
                final picked = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: _audioExtensions,
                );
                if (picked == null || picked.files.isEmpty) return;
                final path = picked.files.first.path;
                if (path == null) return;
                final relative = await repo.importMedia(
                  c.project,
                  File(path),
                  '.${path.split('.').last}',
                );
                final abs = await repo.resolveMedia(c.project, relative);
                c.setMusic(
                  AudioTrack(
                    id: 'track-${DateTime.now().millisecondsSinceEpoch}',
                    assetPath: abs.path,
                  ),
                );
                setSheetState(() {});
              },
            ),
            const Divider(),
            for (final cue in c.frame.audio)
              ListTile(
                leading: const Icon(Icons.audiotrack_rounded),
                title: Text(cue.assetPath.split('/').last),
                subtitle: Slider(
                  value: cue.volume,
                  onChanged: (v) {
                    cue.volume = v;
                    setSheetState(() {});
                  },
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () {
                    c.removeAudioCue(cue.id);
                    setSheetState(() {});
                  },
                ),
              ),
            if (c.frame.audio.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  s.t('noSounds'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: paletteOf(ctx).textDim),
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------------

const _imageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif'];

void showBackgroundSheet(BuildContext context, EditorController c) {
  final s = Strings.of(context);
  _open(
    context,
    StatefulBuilder(
      builder: (ctx, setSheetState) {
        final bg = c.sequence.background;
        return _Sheet(
          title: s.t('background'),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    s.t('backgroundColor'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final color in const [
                        0xFFFFFFFF,
                        0xFF11141A,
                        0xFFF4F5F8,
                        0xFF1E2A44,
                        0xFF2D1B3D,
                        0xFF123B2E,
                        0xFF3B2314,
                      ])
                        GestureDetector(
                          onTap: () {
                            c.mutate(() => bg.color = color);
                            setSheetState(() {});
                          },
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Color(color),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: bg.color == color
                                    ? paletteOf(ctx).accent
                                    : paletteOf(ctx).border,
                                width: bg.color == color ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (bg.imageAssetPath != null)
                    Column(
                      children: [
                        Text(
                          bg.imageAssetPath!.split('/').last,
                          style: TextStyle(color: paletteOf(ctx).textDim),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            c.mutate(() => bg.imageAssetPath = null);
                            setSheetState(() {});
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: Text(s.t('removeImage')),
                        ),
                      ],
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: () async {
                        final repo = context.read<ProjectRepository>();
                        final picked = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: _imageExtensions,
                        );
                        if (picked == null || picked.files.isEmpty) return;
                        final path = picked.files.first.path;
                        if (path == null) return;
                        final relative = await repo.importMedia(
                          c.project,
                          File(path),
                          '.${path.split('.').last}',
                        );
                        c.mutate(() => bg.imageAssetPath = relative);
                        setSheetState(() {});
                      },
                      icon: const Icon(Icons.image_rounded),
                      label: Text(s.t('chooseImage')),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

void showExportSheet(BuildContext context, EditorController c) {
  final s = Strings.of(context);
  _open(
    context,
    StatefulBuilder(
      builder: (ctx, setSheetState) {
        double scale = 0.5;

        return _Sheet(
          title: s.t('menuExport'),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${s.t('exportSize')}  ${(c.project.stageWidth * scale).round()}'
                    ' x ${(c.project.stageHeight * scale).round()}',
                  ),
                  Slider(
                    value: scale,
                    min: 0.2,
                    max: 2,
                    divisions: 9,
                    onChanged: (v) {
                      scale = v;
                      setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  ...[
                    if (isVideoExportSupported)
                      _exportButton(
                        ctx,
                        s,
                        Icons.movie_rounded,
                        s.t('exportMp4'),
                        () => _runVideoExport(ctx, c, scale),
                      )
                    else
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        enabled: false,
                        leading: const Icon(Icons.smartphone_rounded),
                        title: Text(s.t('exportMp4')),
                        subtitle: Text(s.t('exportMp4Unavailable')),
                      ),
                    _exportButton(
                      ctx,
                      s,
                      Icons.gif_rounded,
                      s.t('exportGif'),
                      () => _runExport(ctx, c, ExportFormat.gif, scale),
                    ),
                    const SizedBox(height: 10),
                    _exportButton(
                      ctx,
                      s,
                      Icons.grid_view_rounded,
                      s.t('exportSheet'),
                      () => _runExport(ctx, c, ExportFormat.spriteSheet, scale),
                    ),
                    const SizedBox(height: 10),
                    _exportButton(
                      ctx,
                      s,
                      Icons.photo_library_rounded,
                      s.t('exportSequence'),
                      () => _runExport(ctx, c, ExportFormat.pngSequence, scale),
                    ),
                  ],
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

Widget _exportButton(
  BuildContext context,
  Strings s,
  IconData icon,
  String label,
  Future<void> Function() action,
) {
  return FilledButton.icon(
    onPressed: () => action(),
    icon: Icon(icon),
    label: Text(label),
  );
}

/// MP4 export with sound.
///
/// Shown without `await` so encoding starts immediately; the dialog is closed
/// in the `finally` block so a failed export can never leave a modal blocking
/// the editor.
Future<void> _runVideoExport(
  BuildContext context,
  EditorController c,
  double scale,
) async {
  final s = Strings.of(context);
  final repo = context.read<ProjectRepository>();
  final dir = await repo.projectDir(c.project.id);
  final outDir = Directory('${dir.path}/exports');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final safe = c.project.name
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
      .trim()
      .replaceAll(' ', '_');
  final outFile = File(
    '${outDir.path}/${safe.isEmpty ? 'animacao' : safe}.mp4',
  );

  if (!context.mounted) return;
  final navigator = Navigator.of(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgressDialog(title: s.t('exporting')),
    ),
  );

  final messenger = ScaffoldMessenger.of(context);
  try {
    final renderer = SequenceExporter(controller: c)..scale = scale;
    final exporter = VideoExporter(
      stageWidth: c.project.stageWidth,
      stageHeight: c.project.stageHeight,
    );
    final result = await exporter.export(
      sequence: c.sequence,
      renderer: renderer,
      outputPath: outFile.path,
      scale: scale,
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${s.t('exportDone')} ${result.path}'
            '${result.hasAudio ? '\n${s.f('exportVideoDone', {'0': (result.durationMs / 1000).toStringAsFixed(1)})}' : ''}',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${s.t('genericError')}: $e')));
  } finally {
    if (navigator.canPop()) navigator.pop();
  }
}

class _ExportProgressDialog extends StatelessWidget {
  const _ExportProgressDialog({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(),
          SizedBox(height: 12),
          Text('Pode levar alguns minutos.'),
        ],
      ),
    );
  }
}

Future<void> _runExport(
  BuildContext context,
  EditorController c,
  ExportFormat format,
  double scale,
) async {
  final s = Strings.of(context);
  final repo = context.read<ProjectRepository>();
  final dir = await repo.projectDir(c.project.id);
  final outDir = Directory('${dir.path}/exports');
  final messenger = ScaffoldMessenger.of(context);

  messenger.showSnackBar(SnackBar(content: Text(s.t('exporting'))));

  try {
    final exporter = SequenceExporter(controller: c)..scale = scale;
    final result = await exporter.export(format: format, outputDir: outDir);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${s.t('exportDone')} ${result.path}'
            '${result.note == null ? '' : '\n${result.note}'}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    if (context.mounted) Navigator.pop(context);
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${s.t('genericError')}: $e')));
  }
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/// Edits the selected [TextObject]: content, size, colour and bubble style.
void showTextEditor(BuildContext context, EditorController c) {
  final s = Strings.of(context);
  final selected = c.selectedObject;
  if (selected is! TextObject) return;

  final textController = TextEditingController(text: selected.text);
  var working = selected.copy(selected.id);

  _open(
    context,
    StatefulBuilder(
      builder: (ctx, setSheetState) => _Sheet(
        title: s.t('textTool'),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: textController,
                  minLines: 1,
                  maxLines: 4,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: s.t('textPlaceholder'),
                  ),
                ),
                const SizedBox(height: 12),
                _slider(ctx, s.t('thickness'), working.fontSize, 10, 72, (v) {
                  working = working.copy(working.id, fontSize: v);
                  setSheetState(() {});
                }),
                const SizedBox(height: 6),
                Text(
                  s.t('color'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _colorRow(ctx, working.color, (color) {
                  working = working.copy(working.id, color: color);
                  setSheetState(() {});
                }),
                const SizedBox(height: 14),
                Text(
                  s.t('bubble'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                SegmentedButton<BubbleStyle>(
                  segments: [
                    ButtonSegment(
                      value: BubbleStyle.none,
                      label: Text(s.t('bubbleNone')),
                    ),
                    ButtonSegment(
                      value: BubbleStyle.rounded,
                      label: Text(s.t('bubbleRounded')),
                    ),
                    ButtonSegment(
                      value: BubbleStyle.tailRight,
                      label: Text(s.t('bubbleTail')),
                    ),
                  ],
                  selected: {working.bubble},
                  onSelectionChanged: (v) {
                    working = working.copy(working.id, bubble: v.first);
                    setSheetState(() {});
                  },
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () {
                    c.updateObject(
                      working.copy(
                        working.id,
                        text: textController.text.trim().isEmpty
                            ? s.t('textPlaceholder')
                            : textController.text.trim(),
                      ),
                    );
                    Navigator.pop(ctx);
                  },
                  child: Text(s.t('menuSave')),
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _colorRow(BuildContext context, int current, ValueChanged<int> onPick) {
  const swatches = <int>[
    0xFF14161A,
    0xFFFFFFFF,
    0xFF3B82F6,
    0xFFEF4444,
    0xFFF59E0B,
    0xFF10B981,
    0xFF8B5CF6,
    0xFFEC4899,
    0xFF0EA5E9,
    0xFF92400E,
  ];
  final p = paletteOf(context);
  return Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final c in swatches)
        GestureDetector(
          onTap: () => onPick(c),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border: Border.all(
                color: current == c ? p.accent : p.border,
                width: current == c ? 3 : 1,
              ),
            ),
          ),
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Sprites
// ---------------------------------------------------------------------------

/// Imports an image (or animated GIF) and drops it on the stage.
///
/// Animated GIFs are stored as sprite sheets: every frame of the GIF becomes
/// one cell, and the renderer plays them back at [SpriteObject.spriteFps].
Future<void> importSprite(
  BuildContext context,
  EditorController c, {
  Vec2? at,
}) async {
  final s = Strings.of(context);
  final messenger = ScaffoldMessenger.of(context);

  FilePickerResult? picked;
  try {
    picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _imageExtensions,
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('${s.t('genericError')}: $e')),
    );
    return;
  }
  if (picked == null || picked.files.isEmpty) return;
  final path = picked.files.first.path;
  if (path == null) return;

  final repo = context.read<ProjectRepository>();
  final extension = '.${path.split('.').last.toLowerCase()}';
  final relative = await repo.importMedia(c.project, File(path), extension);
  final absolute = (await repo.resolveMedia(c.project, relative)).path;

  final analysis = await analyseMedia(absolute);
  if (analysis == null) {
    messenger.showSnackBar(SnackBar(content: Text(s.t('genericError'))));
    return;
  }

  final sprite = SpriteObject(
    id: 'sprite-${DateTime.now().millisecondsSinceEpoch}',
    assetPath: absolute,
    naturalWidth: analysis.width.toDouble(),
    naturalHeight: analysis.height.toDouble(),
    spriteFrames: analysis.frames,
    spriteFps: analysis.fps,
    // A vertical strip keeps the natural aspect and needs no padding math.
    spriteColumns: 1,
    spriteRows: analysis.frames,
    transform: Transform2D(translation: at ?? const Vec2(240, 320)),
  );

  c.addObject(sprite);
  if (context.mounted) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${sprite.name.isEmpty ? relative : sprite.name} - ${analysis.frames} frame(s)',
        ),
      ),
    );
  }
}

class MediaAnalysis {
  const MediaAnalysis(this.width, this.height, this.frames, this.fps);

  final int width;
  final int height;
  final int frames;
  final double fps;
}

/// Reads the dimensions of an image, and for animated GIFs counts the frames
/// and their average duration.
Future<MediaAnalysis?> analyseMedia(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width;
    final h = frame.image.height;
    frame.image.dispose();

    int count = 0;
    var totalMs = 0.0;
    while (count < 600) {
      final f = await codec.getNextFrame();
      if (count > 0) f.image.dispose();
      totalMs += f.duration.inMicroseconds / 1000.0;
      count++;
    }
    codec.dispose();

    final realFrames = count <= 1 ? 1 : count - 1;
    final fps = realFrames <= 1
        ? 0.0
        : (realFrames * 1000.0 / totalMs).clamp(1.0, 30.0);
    return MediaAnalysis(w, h, realFrames, fps);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Movieclips
// ---------------------------------------------------------------------------

void showMovieclipSheet(BuildContext context, EditorController c) {
  final s = Strings.of(context);
  _open(
    context,
    StatefulBuilder(
      builder: (ctx, setSheetState) => _Sheet(
        title: s.t('movieclip'),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: Text(s.t('createClip')),
              subtitle: Text('${s.t('toolFigure')}'),
              onTap: () {
                final clip = c.createMovieclipFromSelection('Clip');
                Navigator.pop(ctx);
                if (clip != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${clip.name} criado')),
                  );
                }
              },
            ),
            const Divider(),
            if (c.project.movieclips.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  s.t('noClips'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: paletteOf(ctx).textDim),
                ),
              ),
            for (final clip in c.project.movieclips)
              ListTile(
                leading: const Icon(Icons.movie_filter_rounded),
                title: Text(clip.name),
                subtitle: Text('${clip.sequence.frames.length} frames'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Usar',
                      icon: const Icon(Icons.add_location_alt_rounded),
                      onPressed: () {
                        c.addObject(
                          MovieclipObject(
                            id: 'clip-${DateTime.now().microsecondsSinceEpoch}',
                            clipId: clip.id,
                            lengthFrames: clip.sequence.frames.length,
                            transform: const Transform2D(
                              translation: Vec2(240, 320),
                            ),
                          ),
                        );
                        Navigator.pop(ctx);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () {
                        c.deleteMovieclip(clip.id);
                        setSheetState(() {});
                      },
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}
