import 'dart:ui' as ui;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../data/geometry.dart';
import '../data/models.dart';
import '../data/project_repository.dart';
import '../editor/canvas_painter.dart';
import '../editor/editor_controller.dart';
import '../editor/interpolation.dart';
import '../editor/media_cache.dart';
import '../editor/stick_rigs.dart';
import '../editor/viewport.dart';
import '../l10n/strings.dart';
import '../playback/player.dart';
import 'editor_panels.dart';

/// The editing surface.
///
/// Layout follows the "simple mode" complaint directly: the default view is
/// canvas + one big Add Frame button + play. The timeline, layers and every
/// other control live behind an explicit toggle, so a first-time user is never
/// confronted with eleven toolbars at once.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.handle});

  final ProjectHandle handle;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  late final EditorController _controller;
  final MediaCache _media = MediaCache();

  late final SequencePlayer _player = SequencePlayer();
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  bool _playerAttached = false;

  Vec2 _userPan = Vec2.zero;
  double _userZoom = 1.0;

  /// Background images are picked as a path relative to the project folder.
  /// Decoding is async, so the decoded image is cached here and refreshed
  /// whenever the path changes rather than on every repaint.
  ui.Image? _backgroundImage;
  String? _backgroundImagePath;
  int _backgroundStamp = -1;

  void _syncBackgroundImage() {
    final relative = _controller.sequence.background.imageAssetPath;
    final stamp = relative?.hashCode ?? -1;
    if (stamp == _backgroundStamp) return;
    _backgroundStamp = stamp;

    final previous = _backgroundImage;
    _backgroundImage = null;
    _backgroundImagePath = relative == null
        ? null
        : '${widget.handle.directory.path}/$relative';
    if (previous != null) previous.dispose();

    final path = _backgroundImagePath;
    if (path == null) return;
    // Fire and forget: the painter shows nothing until the image lands, then
    // the next repaint picks it up.
    _media.load(path).then((img) {
      if (!mounted || img == null) return;
      if (_backgroundImagePath != path) {
        img.dispose();
        return;
      }
      _backgroundImage = img;
      setState(() {});
    });
  }

  // Drag state
  String? _draggingObjectId;
  Anchor? _draggingAnchor;
  Vec2 _dragStartScene = Vec2.zero;
  Transform2D _dragStartTransform = Transform2D.identity;
  Vec2 _dragStartAnchor = Vec2.zero;
  bool _dragMoved = false;

  /// Points collected while the pen tool is drawing. Null when not drawing.
  List<Vec2>? _strokePoints;

  /// Live style used by the pen / shape tools.
  int _inkColor = StickRigs.defaultColor;
  double _inkThickness = StickRigs.defaultThickness;

  @override
  void initState() {
    super.initState();
    _controller = EditorController(
      project: widget.handle.project,
      directoryPath: widget.handle.directory.path,
      repository: context.read<ProjectRepository>(),
    );
    _ticker = createTicker(_onTick);
    _player.addListener(_onPlayerChanged);
  }

  @override
  void dispose() {
    _controller.flush();
    _controller.dispose();
    _player.dispose();
    _ticker.dispose();
    _media.dispose();
    super.dispose();
  }

  void _onTick(Duration now) {
    if (_lastTick == Duration.zero) _lastTick = now;
    final dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    _player.update(dt);
    _syncPlayhead();
  }

  void _syncPlayhead() {
    if (!mounted) return;
    setState(() {});
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  /// Hardware back in the editor should stop playback first, not leave the
  /// animation running behind a half-closed screen.
  Future<bool> _onWillPop() async {
    if (_player.isPlaying) {
      _player.stop();
      return false;
    }
    await _controller.flush();
    return true;
  }

  StageViewport _viewport(Size size) => StageViewport(
    canvasSize: size,
    stageSize: Vec2(
      _controller.project.stageWidth,
      _controller.project.stageHeight,
    ),
    userPan: _userPan,
    userZoom: _userZoom,
    cameraCenter: _controller.currentCamera.center,
    cameraZoom: _controller.currentCamera.zoom,
    cameraRotation: _controller.currentCamera.rotation,
  );

  // -------------------------------------------------------------------------
  // Gesture handling
  // -------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails d, Size size) {
    final vp = _viewport(size);
    _dragStartScene = vp.viewToScene(
      Vec2(d.localFocalPoint.dx, d.localFocalPoint.dy),
    );
    if (_controller.tool == EditorTool.pen) {
      _strokePoints = <Vec2>[_dragStartScene];
      return;
    }

    final obj = _pick(_dragStartScene, vp);
    _dragMoved = false;

    if (obj is FigureObject && obj.showJoints) {
      final anchor = _pickAnchor(obj, _dragStartScene, vp);
      if (anchor != null) {
        _draggingAnchor = anchor;
        _draggingObjectId = obj.id;
        _dragStartAnchor = obj.anchors[anchor]!;
        return;
      }
    }

    _draggingObjectId = obj?.id;
    _dragStartTransform = obj?.transform ?? Transform2D.identity;
    if (obj != null) {
      _controller.selectObjectSilently(obj.id);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    final vp = _viewport(size);

    // Two fingers: navigate the view. One finger: edit.
    if (d.pointerCount > 1) {
      setState(() {
        _userZoom = (_userZoom * d.scale).clamp(0.2, 10.0);
      });
      return;
    }

    final sceneNow = vp.viewToScene(
      Vec2(d.localFocalPoint.dx, d.localFocalPoint.dy),
    );

    if (_strokePoints != null) {
      // Drop sub-pixel jitter: fewer points means a smaller file and a
      // smoother-looking line once the stroke is drawn.
      if ((sceneNow - _strokePoints!.last).lengthSquared > 1.5) {
        _strokePoints!.add(sceneNow);
        setState(() {});
      }
      return;
    }

    if (_draggingObjectId == null) {
      // Panning with the pan tool or on empty space.
      if (_controller.tool == EditorTool.pan ||
          d.focalPointDelta.distance > 0) {
        if (_controller.tool == EditorTool.pan) {
          setState(
            () => _userPan =
                _userPan + Vec2(d.focalPointDelta.dx, d.focalPointDelta.dy),
          );
        }
      }
      return;
    }

    final delta = sceneNow - _dragStartScene;
    if (delta.length > 0.5) _dragMoved = true;

    if (_draggingAnchor != null) {
      _controller.mutateLive(() {
        _controller.moveAnchorLive(
          _draggingObjectId!,
          _draggingAnchor!,
          _dragStartAnchor + delta,
        );
      });
    } else {
      _controller.mutateLive(() {
        _controller.moveObjectLive(
          _draggingObjectId!,
          _dragStartTransform.copyWith(
            translation: _dragStartTransform.translation + delta,
          ),
        );
      });
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final points = _strokePoints;
    if (points != null) {
      _strokePoints = null;
      if (points.length >= 2) {
        _controller.mutate(() {
          _controller.addObject(
            StrokeObject(
              id: _newId('stroke'),
              points: points,
              color: _inkColor,
              thickness: _inkThickness,
            ),
          );
        });
      }
      setState(() {});
      return;
    }

    if (_dragMoved && _draggingObjectId != null) {
      // One undo step per gesture, not per pixel.
      _controller.commitLive();
    }
    _draggingObjectId = null;
    _draggingAnchor = null;
    _dragMoved = false;
  }

  void _onDoubleTap(Size size, Vec2 at) {
    // Double tap on empty canvas centres the view on that spot.
    setState(() {
      _userPan = Vec2.zero;
      _userZoom = 1.0;
    });
  }

  void _onTapUp(TapUpDetails d, Size size) {
    final s = Strings.of(context);
    final vp = _viewport(size);
    final scene = vp.viewToScene(Vec2(d.localPosition.dx, d.localPosition.dy));

    if (_controller.tool == EditorTool.figure) {
      _addFigureAt(scene);
      return;
    }
    if (_controller.tool == EditorTool.circle) {
      _controller.addObject(
        CircleObject(
          id: _newId('circ'),
          center: scene,
          radius: 28,
          thickness: _inkThickness,
          color: _inkColor,
        ),
      );
      return;
    }

    if (_controller.tool == EditorTool.text) {
      _controller.addObject(
        TextObject(
          id: _newId('text'),
          text: s.t('textPlaceholder'),
          transform: Transform2D(translation: scene),
        ),
      );
      _controller.tool = EditorTool.select;
      showTextEditor(context, _controller);
      setState(() {});
      return;
    }

    if (_controller.tool == EditorTool.sprite) {
      importSprite(context, _controller, at: scene);
      setState(() {});
      return;
    }

    final picked = _pick(scene, vp);
    _controller.selectObjectSilently(picked?.id);
    setState(() {});
  }

  void _addFigureAt(Vec2 scene) {
    final fig = StickRigs.standing(at: scene);
    _controller.addFigure(fig);
    setState(() {});
  }

  SceneObject? _pick(Vec2 scenePoint, StageViewport vp) {
    final scene = _controller.resolveAt(_controller.currentFrame.toDouble());
    final objects = _controller.visibleObjects(scene);
    // Topmost first: draw order is last-in-list.
    for (var i = objects.length - 1; i >= 0; i--) {
      final o = objects[i];
      if (o.locked) continue;
      final bounds = o.localBounds.transformedBy(o.transform).expanded(8);
      if (bounds.contains(scenePoint)) return o;
    }
    return null;
  }

  Anchor? _pickAnchor(FigureObject fig, Vec2 scenePoint, StageViewport vp) {
    const handleRadius = 12.0;
    Anchor? best;
    var bestDist = handleRadius * handleRadius;
    fig.anchors.forEach((anchor, local) {
      final world = fig.transform.applyLocal(local);
      final d = (world - scenePoint).lengthSquared;
      if (d < bestDist) {
        bestDist = d;
        best = anchor;
      }
    });
    return best;
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = paletteOf(context);
    _syncBackgroundImage();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onWillPop() && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: p.background,
        appBar: _buildAppBar(s, p),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: _buildCanvasArea(s, p)),
              _buildInkRow(p),
              _buildToolBar(s, p),
              _buildTransport(s, p),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                child: _controller.simpleMode
                    ? _buildQuickBar(s, p)
                    : _buildTimeline(s, p),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(Strings s, AppPalette p) {
    return AppBar(
      title: GestureDetector(
        onTap: () => _renameProject(s),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _controller.project.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.edit_rounded, size: 15, color: p.textDim),
          ],
        ),
      ),
      actions: [
        _SaveIndicator(),
        IconButton(
          tooltip: s.t('undo'),
          icon: const Icon(Icons.undo_rounded),
          onPressed: _controller.canUndo
              ? () {
                  _controller.undo();
                  setState(() {});
                }
              : null,
        ),
        IconButton(
          tooltip: s.t('redo'),
          icon: const Icon(Icons.redo_rounded),
          onPressed: _controller.canRedo
              ? () {
                  _controller.redo();
                  setState(() {});
                }
              : null,
        ),
        IconButton(
          tooltip: s.t('menuExport'),
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: () => showExportSheet(context, _controller),
        ),
      ],
    );
  }

  Widget _buildCanvasArea(Strings s, AppPalette p) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final vp = _viewport(size);
        final position = _player.isPlaying
            ? _player.position
            : _controller.currentFrame.toDouble();

        final scene = _controller.resolveAt(position);
        final objects = _controller.visibleObjects(scene);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) => _onScaleStart(d, size),
          onScaleUpdate: (d) => _onScaleUpdate(d, size),
          onScaleEnd: _onScaleEnd,
          onDoubleTapDown: (d) => _onDoubleTap(
            size,
            vp.viewToScene(Vec2(d.localPosition.dx, d.localPosition.dy)),
          ),
          onTapUp: (d) => _onTapUp(d, size),
          child: RepaintBoundary(
            child: CustomPaint(
              size: size,
              painter: ScenePainter(
                viewport: vp,
                objects: objects,
                backgroundColor: Color(_controller.sequence.background.color),
                backgroundImage: _backgroundImage,
                media: _media,
                onion: _buildOnion(),
                selectedId: _controller.selectedObjectId,
                activeStroke: _strokePoints,
                activeStrokeColor: _inkColor,
                activeStrokeThickness: _inkThickness,
                frameIndex: position.round(),
                emptyHint: 'Toque em Boneco e depois no palco',
              ),
            ),
          ),
        );
      },
    );
  }

  List<OnionLayer> _buildOnion() {
    if (!_controller.showOnionSkin) return const [];
    final frames = _controller.sequence.frames;
    final out = <OnionLayer>[];
    final idx = _controller.currentFrame;

    for (var d = _controller.onionAfter; d >= 1; d--) {
      final i = idx + d;
      if (i >= frames.length) break;
      final scene = _controller.resolveAt(i.toDouble());
      out.add(
        OnionLayer(
          _controller.visibleObjects(scene),
          const Color(0xFF4C8DFF),
          (0.30 / d).clamp(0.04, 0.3),
        ),
      );
    }
    for (var d = _controller.onionBefore; d >= 1; d--) {
      final i = idx - d;
      if (i < 0) break;
      final scene = _controller.resolveAt(i.toDouble());
      out.add(
        OnionLayer(
          _controller.visibleObjects(scene),
          const Color(0xFFFF6B6B),
          (0.30 / d).clamp(0.04, 0.3),
        ),
      );
    }
    return out;
  }

  /// Ink style row, shown only when a drawing tool is active so it never gets
  /// in the way of the common case.
  Widget _buildInkRow(AppPalette p) {
    final drawing =
        _controller.tool == EditorTool.pen ||
        _controller.tool == EditorTool.circle;
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      child: drawing
          ? Container(
              color: p.surfaceAlt,
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Row(
                children: [
                  for (final color in const [
                    0xFF14161A,
                    0xFFFFFFFF,
                    0xFF3B82F6,
                    0xFFEF4444,
                    0xFFF59E0B,
                    0xFF10B981,
                    0xFF8B5CF6,
                  ])
                    GestureDetector(
                      onTap: () => setState(() => _inkColor = color),
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Color(color),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _inkColor == color ? p.accent : p.border,
                            width: _inkColor == color ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  SizedBox(
                    width: 120,
                    child: Slider(
                      value: _inkThickness,
                      min: 2,
                      max: 24,
                      onChanged: (v) => setState(() => _inkThickness = v),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _buildToolBar(Strings s, AppPalette p) {
    Widget tool(EditorTool t, IconData icon, String label) {
      final active = _controller.tool == t;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _controller.tool = t),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: active ? p.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: active ? p.accent : p.textDim),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  style: TextStyle(
                    fontSize: 10,
                    color: active ? p.accent : p.textDim,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: p.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          tool(EditorTool.select, Icons.near_me_rounded, s.t('toolSelect')),
          tool(
            EditorTool.figure,
            Icons.accessibility_new_rounded,
            s.t('toolFigure'),
          ),
          tool(EditorTool.pen, Icons.edit_rounded, s.t('toolPen')),
          tool(EditorTool.circle, Icons.circle_outlined, s.t('toolCircle')),
          tool(EditorTool.text, Icons.title_rounded, s.t('toolText')),
          tool(EditorTool.sprite, Icons.image_rounded, s.t('toolSprite')),
        ],
      ),
    );
  }

  Widget _buildTransport(Strings s, AppPalette p) {
    final seq = _controller.sequence;
    final total = seq.frames.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: p.surface,
      child: Row(
        children: [
          IconButton(
            tooltip: s.t('simpleMode'),
            icon: Icon(
              _controller.simpleMode
                  ? Icons.view_agenda_outlined
                  : Icons.tune_rounded,
              color: _controller.simpleMode ? p.accent : p.textDim,
            ),
            onPressed: () => setState(
              () => _controller.simpleMode = !_controller.simpleMode,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: s.t('undo'),
            icon: const Icon(Icons.chevron_left_rounded, size: 28),
            onPressed: total > 1 && _controller.currentFrame > 0
                ? () => setState(
                    () => _controller.selectFrame(_controller.currentFrame - 1),
                  )
                : null,
          ),
          IconButton.filled(
            onPressed: () {
              if (!_playerAttached) {
                _player.load(
                  seq,
                  position: _controller.currentFrame.toDouble(),
                );
                _playerAttached = true;
                _ticker.start();
              }
              _player.toggle();
              setState(() {});
            },
            icon: Icon(
              _player.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
            ),
          ),
          IconButton(
            tooltip: s.t('undo'),
            icon: const Icon(Icons.chevron_right_rounded, size: 28),
            onPressed: _controller.currentFrame < total - 1
                ? () => setState(
                    () => _controller.selectFrame(_controller.currentFrame + 1),
                  )
                : null,
          ),
          Text(
            '${_player.isPlaying ? _player.position.floor() + 1 : _controller.currentFrame + 1}'
            ' / $total',
            style: TextStyle(
              color: p.textDim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: s.t('onionSkin'),
            icon: Icon(
              Icons.blur_on_rounded,
              color: _controller.showOnionSkin ? p.accent : p.textDim,
            ),
            onPressed: () => setState(
              () => _controller.showOnionSkin = !_controller.showOnionSkin,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickBar(Strings s, AppPalette p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      color: p.surface,
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () {
                _controller.addFrame();
                setState(() {});
              },
              icon: const Icon(Icons.add_rounded),
              label: Text(s.t('addFrame')),
            ),
          ),
          const SizedBox(width: 10),
          _RoundIconButton(
            icon: Icons.face_rounded,
            tooltip: s.t('toolFigure'),
            onTap: () => showPoseSheet(context, _controller, _newId),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline(Strings s, AppPalette p) {
    final frames = _controller.sequence.frames;

    return Container(
      color: p.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 76,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              itemCount: frames.length,
              itemBuilder: (context, i) {
                final selected = i == _controller.currentFrame;
                return GestureDetector(
                  onTap: () => setState(() => _controller.selectFrame(i)),
                  onLongPress: () => _confirmDeleteFrame(i),
                  child: Container(
                    width: 52,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: selected ? p.accentSoft : p.surfaceAlt,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: selected ? p.accent : p.border,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: selected ? p.accent : p.text,
                          ),
                        ),
                        if (frames[i].hold > 1)
                          Text(
                            '${frames[i].hold}x',
                            style: TextStyle(fontSize: 10, color: p.textDim),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                IconButton(
                  tooltip: s.t('addFrame'),
                  icon: const Icon(Icons.add_rounded),
                  onPressed: () {
                    _controller.addFrame();
                    setState(() {});
                  },
                ),
                IconButton(
                  tooltip: s.t('duplicateFrame'),
                  icon: const Icon(Icons.copy_all_rounded),
                  onPressed: () {
                    _controller.duplicateFrame();
                    setState(() {});
                  },
                ),
                IconButton(
                  tooltip: s.t('layers'),
                  icon: const Icon(Icons.layers_rounded),
                  onPressed: () => showLayerSheet(context, _controller, _newId),
                ),
                IconButton(
                  tooltip: s.t('camera'),
                  icon: const Icon(Icons.videocam_rounded),
                  onPressed: () => showCameraSheet(context, _controller),
                ),
                IconButton(
                  tooltip: s.t('audio'),
                  icon: const Icon(Icons.graphic_eq_rounded),
                  onPressed: () => showAudioSheet(context, _controller),
                ),
                IconButton(
                  tooltip: s.t('background'),
                  icon: const Icon(Icons.wallpaper_rounded),
                  onPressed: () => showBackgroundSheet(context, _controller),
                ),
                IconButton(
                  tooltip: s.t('movieclip'),
                  icon: const Icon(Icons.movie_filter_rounded),
                  onPressed: () => showMovieclipSheet(context, _controller),
                ),
                const Spacer(),
                _fpsButton(s, p),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fpsButton(Strings s, AppPalette p) {
    final fps = _controller.sequence.fps;
    return PopupMenuButton<int>(
      tooltip: s.t('fps'),
      onSelected: (v) => setState(() => _controller.sequence.fps = v),
      itemBuilder: (ctx) => const [
        6,
        8,
        10,
        12,
        15,
        24,
      ].map((v) => PopupMenuItem(value: v, child: Text('$v fps'))).toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Text(
              '$fps',
              style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
            ),
            Text(' fps', style: TextStyle(color: p.textDim, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteFrame(int index) async {
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('deleteFrame')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('menuCancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('menuDelete')),
          ),
        ],
      ),
    );
    if (ok == true) {
      _controller.deleteFrame(index);
      setState(() {});
    }
  }

  Future<void> _renameProject(Strings s) async {
    final controller = TextEditingController(text: _controller.project.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.t('menuCancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(s.t('menuSave')),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      _controller.mutate(() => _controller.project.name = name.trim());
      setState(() {});
    }
  }
}

String _newId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: SizedBox(
        width: 48,
        height: 48,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(48, 48),
          ),
          child: Icon(icon),
        ),
      ),
    );
  }
}

/// Small cloud indicator. Listens to the repository's save state so the user
/// can always tell whether their work is on disk.
class _SaveIndicator extends StatefulWidget {
  const _SaveIndicator();

  @override
  State<_SaveIndicator> createState() => _SaveIndicatorState();
}

class _SaveIndicatorState extends State<_SaveIndicator> {
  SaveState _state = SaveState.idle;
  ProjectRepository? _repo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = context.read<ProjectRepository>();
    if (identical(repo, _repo)) return;
    _repo?.removeSaveStateListener(_onChanged);
    _repo = repo;
    _state = repo.saveState;
    repo.addSaveStateListener(_onChanged);
  }

  @override
  void dispose() {
    _repo?.removeSaveStateListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() => _state = _repo?.saveState ?? SaveState.idle);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = paletteOf(context);
    final (icon, color, label) = switch (_state) {
      SaveState.dirty => (
        Icons.cloud_upload_outlined,
        p.textDim,
        s.t('saving'),
      ),
      SaveState.saving => (Icons.cloud_sync_rounded, p.textDim, s.t('saving')),
      SaveState.saved => (Icons.cloud_done_rounded, p.success, s.t('saved')),
      SaveState.failed => (
        Icons.cloud_off_rounded,
        p.danger,
        s.t('saveFailed'),
      ),
      SaveState.idle => (Icons.cloud_queue_rounded, p.textDim, s.t('saved')),
    };
    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }
}
