import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';
import '../data/geometry.dart';
import '../data/models.dart';
import '../data/project_codec.dart';
import '../data/project_repository.dart';
import 'interpolation.dart';
import 'stick_rigs.dart';

enum EditorTool { select, figure, pen, text, circle, sprite, pan }

/// Central editor state.
///
/// Every mutation goes through [mutate], which snapshots for undo and kicks the
/// autosave timer. Nothing else is allowed to touch the project's JSON.
class EditorController extends ChangeNotifier {
  EditorController({
    required this.project,
    required this.directoryPath,
    required ProjectRepository repository,
  }) : _repo = repository {
    _pushUndo();
  }

  Project project;
  final String directoryPath;
  final ProjectRepository _repo;

  Sequence get sequence => project.activeSequence;
  set sequence(Sequence s) {
    project.activeSequenceId = s.id;
    notifyListeners();
  }

  int currentFrame = 0;
  String? selectedObjectId;
  String? selectedLayerId;
  EditorTool tool = EditorTool.select;
  bool showOnionSkin = false;
  int onionBefore = 1;
  int onionAfter = 1;
  bool simpleMode = false;

  // -------------------------------------------------------------------------
  // Undo / redo
  // -------------------------------------------------------------------------

  final List<String> _undo = [];
  final List<String> _redo = [];
  static const int _historyLimit = 60;

  bool get canUndo => _undo.length > 1;
  bool get canRedo => _redo.isNotEmpty;

  void _pushUndo() {
    _undo.add(ProjectCodec.encode(project));
    if (_undo.length > _historyLimit) _undo.removeAt(0);
    _redo.clear();
  }

  /// Runs [action], recording one undo step and scheduling an autosave.
  ///
  /// Returns whatever [action] returned. If [action] throws, nothing is
  /// recorded and the model is restored, so a failed edit cannot leave the
  /// project in a half-applied state.
  T mutate<T>(T Function() action) {
    final before = ProjectCodec.encode(project);
    try {
      final result = action();
      final after = ProjectCodec.encode(project);
      if (before != after) {
        _undo.add(before);
        if (_undo.length > _historyLimit) _undo.removeAt(0);
        _redo.clear();
        project.modifiedAt = DateTime.now().millisecondsSinceEpoch;
        _repo.scheduleAutosave(project);
      }
      notifyListeners();
      return result;
    } catch (e) {
      // Roll back to the last known-good state.
      try {
        project = ProjectCodec.decode(before);
      } catch (_) {
        // Extremely unlikely; keep going so the user still sees something.
      }
      notifyListeners();
      rethrow;
    }
  }

  /// Mutates without touching history. For continuous gestures (dragging a
  /// handle) where each pixel would otherwise become an undo step.
  void mutateLive(T Function() action) {
    action();
    notifyListeners();
    _repo.scheduleAutosave(project);
  }

  /// Commits the accumulated live changes into a single undo step.
  void commitLive() {
    _pushUndo();
    project.modifiedAt = DateTime.now().millisecondsSinceEpoch;
    _repo.scheduleAutosave(project);
  }

  void undo() {
    if (_undo.length < 2) return;
    final current = _undo.removeLast();
    _redo.add(current);
    project = ProjectCodec.decode(_undo.last);
    _clampSelection();
    notifyListeners();
    _repo.scheduleAutosave(project);
  }

  void redo() {
    if (_redo.isEmpty) return;
    final next = _redo.removeLast();
    _undo.add(next);
    project = ProjectCodec.decode(next);
    _clampSelection();
    notifyListeners();
    _repo.scheduleAutosave(project);
  }

  void _clampSelection() {
    if (sequence.frames.isEmpty) return;
    if (currentFrame >= sequence.frames.length) {
      currentFrame = sequence.frames.length - 1;
    }
    if (currentFrame < 0) currentFrame = 0;
  }

  // -------------------------------------------------------------------------
  // Frame access
  // -------------------------------------------------------------------------

  Frame get frame => sequence.frames[currentFrame];

  bool get hasFrame => sequence.frames.isNotEmpty;

  void selectFrame(int index) {
    if (sequence.frames.isEmpty) return;
    final i = index.clamp(0, sequence.frames.length - 1);
    if (i == currentFrame) return;
    currentFrame = i;
    notifyListeners();
  }

  Layer get _activeLayer {
    for (final l in frame.layers) {
      if (l.id == selectedLayerId) return l;
    }
    if (frame.layers.isEmpty) {
      final l = Layer(id: IdGen.next('layer'), name: 'Camada 1');
      mutate(() => frame.layers.add(l));
      selectedLayerId = l.id;
      notifyListeners();
      return l;
    }
    final first = frame.layers.first;
    selectedLayerId = first.id;
    return first;
  }

  /// Adds a frame and returns its index.
  ///
  /// When [copyPrevious] is true the new frame starts as a deep copy of the
  /// current one. This is the single most requested feature in the genre
  /// ("make the next frame repeat the previous") so it is on by default.
  int addFrame({bool copyPrevious = true}) {
    return mutate(() {
      final newIndex = currentFrame + 1;
      late Frame created;
      if (copyPrevious && sequence.frames.isNotEmpty) {
        created = _deepCopyFrame(frame);
      } else {
        created = Frame(id: IdGen.next('frame'));
        // A brand new frame still needs the layer structure to match, otherwise
        // the layer list flickers every time a frame is added.
        for (final l in frame.layers) {
          created.layers.add(Layer(id: IdGen.next('layer'), name: l.name));
        }
      }
      sequence.frames.insert(newIndex, created);
      currentFrame = newIndex;
      selectedLayerId = created.layers.isNotEmpty
          ? created.layers.first.id
          : null;
      return newIndex;
    });
  }

  Frame _deepCopyFrame(Frame src) {
    // Round-tripping through the codec is the cheapest way to guarantee a real
    // deep copy of a deeply nested tree, and it exercises the same code path
    // that will read the file back later.
    return Frame.fromJson((src.toJson()).cast<String, dynamic>());
  }

  int duplicateFrame() {
    return mutate(() {
      final copy = _deepCopyFrame(frame);
      sequence.frames.insert(currentFrame + 1, copy);
      currentFrame += 1;
      return currentFrame;
    });
  }

  void deleteFrame(int index) {
    if (sequence.frames.length <= 1) return; // never leave zero frames
    mutate(() {
      sequence.frames.removeAt(index);
      if (currentFrame >= sequence.frames.length) {
        currentFrame = sequence.frames.length - 1;
      }
      _clampSelection();
    });
  }

  void moveFrame(int from, int to) {
    if (to < 0 || to >= sequence.frames.length || from == to) return;
    mutate(() {
      final f = sequence.frames.removeAt(from);
      sequence.frames.insert(to, f);
      currentFrame = to;
    });
  }

  void setFrameHold(int frames) {
    mutate(() => frame.hold = frames < 1 ? 1 : frames);
  }

  // -------------------------------------------------------------------------
  // Layers and groups (unlimited - there is deliberately no counter)
  // -------------------------------------------------------------------------

  Layer addLayer({String? parentId}) {
    return mutate(() {
      final l = Layer(
        id: IdGen.next('layer'),
        name: 'Camada',
        parentId: parentId,
      );
      frame.layers.add(l);
      selectedLayerId = l.id;
      return l;
    });
  }

  void deleteLayer(String layerId) {
    mutate(() {
      // Delete children too, otherwise orphans would keep drawing.
      final ids = <String>{layerId};
      var grew = true;
      while (grew) {
        grew = false;
        for (final l in frame.layers) {
          if (l.parentId != null && ids.contains(l.parentId) && ids.add(l.id)) {
            grew = true;
          }
        }
      }
      frame.layers.removeWhere((l) => ids.contains(l.id));
      if (selectedLayerId != null && ids.contains(selectedLayerId)) {
        selectedLayerId = null;
      }
    });
  }

  /// Wraps [layerId] (and everything under it) in a new group layer.
  void groupLayer(String layerId) {
    mutate(() {
      final target = frame.layers.firstWhere((l) => l.id == layerId);
      final group = Layer(
        id: IdGen.next('group'),
        name: 'Grupo ${frame.layers.length}',
      );
      frame.layers.add(group);
      target.parentId = group.id;
      selectedLayerId = group.id;
    });
  }

  void ungroupLayer(String groupId) {
    mutate(() {
      for (final l in frame.layers) {
        if (l.parentId == groupId) l.parentId = null;
      }
      frame.layers.removeWhere((l) => l.id == groupId);
      selectedLayerId = null;
    });
  }

  /// Moves [layerId] to a new index in draw order (0 = back).
  void reorderLayer(String layerId, int newIndex) {
    mutate(() {
      final layers = frame.layers;
      final idx = layers.indexWhere((l) => l.id == layerId);
      if (idx < 0) return;
      final l = layers.removeAt(idx);
      final i = newIndex.clamp(0, layers.length);
      layers.insert(i, l);
    });
  }

  // -------------------------------------------------------------------------
  // Objects
  // -------------------------------------------------------------------------

  SceneObject? get selectedObject {
    if (selectedObjectId == null) return null;
    for (final l in frame.layers) {
      for (final o in l.objects) {
        if (o.id == selectedObjectId) return o;
      }
    }
    return null;
  }

  void addObject(SceneObject obj, {String? layerId}) {
    mutate(() {
      final l = layerId != null
          ? frame.layers.firstWhere((e) => e.id == layerId)
          : _activeLayer;
      l.objects.add(obj);
      selectedObjectId = obj.id;
    });
  }

  void deleteSelected() {
    if (selectedObjectId == null) return;
    mutate(() {
      for (final l in frame.layers) {
        l.objects.removeWhere((o) => o.id == selectedObjectId);
      }
      selectedObjectId = null;
    });
  }

  void duplicateSelected() {
    final o = selectedObject;
    if (o == null) return;
    mutate(() {
      final copy = o.duplicate(IdGen.next('obj'));
      copy.transform = copy.transform.copyWith(
        translation: copy.transform.translation + const Vec2(12, 12),
      );
      for (final l in frame.layers) {
        if (l.objects.contains(o)) {
          l.objects.add(copy);
          selectedObjectId = copy.id;
          return;
        }
      }
    });
  }

  /// Applies [fn] to the selected object, replacing it in place.
  ///
  /// Scene objects are immutable, so this is the standard edit path.
  void updateObject(SceneObject updated) {
    mutate(() {
      for (final l in frame.layers) {
        final i = l.objects.indexWhere((o) => o.id == updated.id);
        if (i >= 0) {
          l.objects[i] = updated;
          return;
        }
      }
    });
  }

  /// Same as [updateObject] but without creating an undo step per frame of a
  /// drag. Pair with [commitLive].
  void updateObjectLive(SceneObject updated) {
    for (final l in frame.layers) {
      final i = l.objects.indexWhere((o) => o.id == updated.id);
      if (i >= 0) {
        l.objects[i] = updated;
        notifyListeners();
        _repo.scheduleAutosave(project);
        return;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Figures
  // -------------------------------------------------------------------------

  void addFigure(FigureObject fig) => addObject(fig);

  /// Moves one anchor of the selected figure. Used by the pose editor.
  void moveAnchor(FigureObject fig, Anchor anchor, Vec2 to) {
    mutate(() {
      final anchors = Map<Anchor, Vec2>.from(fig.anchors);
      anchors[anchor] = to;
      updateFigureAnchors(fig, anchors);
    });
  }

  void updateFigureAnchors(FigureObject fig, Map<Anchor, Vec2> anchors) {
    for (final l in frame.layers) {
      final i = l.objects.indexWhere((o) => o.id == fig.id);
      if (i >= 0) {
        final updated = StickRigs.resolveBones(
          FigureObject(
            id: fig.id,
            name: fig.name,
            bones: fig.bones,
            joints: fig.joints,
            anchors: anchors,
            thickness: fig.thickness,
            color: fig.color,
            showJoints: fig.showJoints,
            transform: fig.transform,
            visible: fig.visible,
            locked: fig.locked,
            opacity: fig.opacity,
          ),
        );
        l.objects[i] = updated;
        return;
      }
    }
  }

  /// Replaces the selected object wholesale (pose swaps, style changes).
  void replaceSelected(SceneObject obj) => updateObject(obj);

  /// Selection that does not create an undo step - used while tapping around
  /// to inspect what is under the finger.
  void selectObjectSilently(String? objectId) {
    selectedObjectId = objectId;
    notifyListeners();
  }

  /// Live drag helpers. These mutate without touching history; pair with
  /// [commitLive] when the gesture ends.
  void moveObjectLive(String objectId, Transform2D transform) {
    for (final l in frame.layers) {
      final i = l.objects.indexWhere((o) => o.id == objectId);
      if (i >= 0) {
        l.objects[i] = _rebuildWithTransform(l.objects[i], transform);
        notifyListeners();
        _repo.scheduleAutosave(project);
        return;
      }
    }
  }

  void moveAnchorLive(String figureId, Anchor anchor, Vec2 to) {
    for (final l in frame.layers) {
      final i = l.objects.indexWhere((o) => o.id == figureId);
      if (i >= 0) {
        final obj = l.objects[i];
        if (obj is! FigureObject) return;
        final anchors = Map<Anchor, Vec2>.from(obj.anchors);
        anchors[anchor] = to;
        l.objects[i] = StickRigs.resolveBones(
          FigureObject(
            id: obj.id,
            name: obj.name,
            bones: obj.bones,
            joints: obj.joints,
            anchors: anchors,
            thickness: obj.thickness,
            color: obj.color,
            showJoints: obj.showJoints,
            transform: obj.transform,
            visible: obj.visible,
            locked: obj.locked,
            opacity: obj.opacity,
          ),
        );
        notifyListeners();
        _repo.scheduleAutosave(project);
        return;
      }
    }
  }

  static SceneObject _rebuildWithTransform(SceneObject o, Transform2D t) {
    switch (o) {
      case StrokeObject():
        return StrokeObject(
          id: o.id,
          points: o.points,
          color: o.color,
          thickness: o.thickness,
          closed: o.closed,
          cap: o.cap,
          name: o.name,
          transform: t,
          visible: o.visible,
          locked: o.locked,
          opacity: o.opacity,
        );
      case CircleObject():
        return CircleObject(
          id: o.id,
          center: o.center,
          radius: o.radius,
          color: o.color,
          thickness: o.thickness,
          filled: o.filled,
          name: o.name,
          transform: t,
          visible: o.visible,
          locked: o.locked,
          opacity: o.opacity,
        );
      case FillObject():
        return FillObject(
          id: o.id,
          points: o.points,
          color: o.color,
          name: o.name,
          transform: t,
          visible: o.visible,
          locked: o.locked,
          opacity: o.opacity,
        );
      case FigureObject():
        return FigureObject(
          id: o.id,
          bones: o.bones,
          joints: o.joints,
          anchors: o.anchors,
          thickness: o.thickness,
          color: o.color,
          showJoints: o.showJoints,
          name: o.name,
          transform: t,
          visible: o.visible,
          locked: o.locked,
          opacity: o.opacity,
        );
      case TextObject():
        return TextObject(
          id: o.id,
          text: o.text,
          fontSize: o.fontSize,
          color: o.color,
          backgroundColor: o.backgroundColor,
          bubble: o.bubble,
          align: o.align,
          padding: o.padding,
          outlineColor: o.outlineColor,
          name: o.name,
          transform: t,
          visible: o.visible,
          locked: o.locked,
          opacity: o.opacity,
        );
      case SpriteObject():
        return SpriteObject(
          id: o.id,
          assetPath: o.assetPath,
          naturalWidth: o.naturalWidth,
          naturalHeight: o.naturalHeight,
          spriteFrames: o.spriteFrames,
          spriteFps: o.spriteFps,
          spriteColumns: o.spriteColumns,
          spriteRows: o.spriteRows,
          name: o.name,
          transform: t,
          visible: o.visible,
          locked: o.locked,
          opacity: o.opacity,
        );
      case MovieclipObject():
        return MovieclipObject(
          id: o.id,
          clipId: o.clipId,
          startFrame: o.startFrame,
          lengthFrames: o.lengthFrames,
          loop: o.loop,
          timeScale: o.timeScale,
          name: o.name,
          transform: t,
          visible: o.visible,
          locked: o.locked,
          opacity: o.opacity,
        );
    }
  }

  // -------------------------------------------------------------------------
  // Camera
  // -------------------------------------------------------------------------

  CameraKey get currentCamera => frame.camera ?? CameraKey.defaultCamera;

  void setCamera(CameraKey cam, {bool keyframe = true}) {
    mutate(() {
      if (keyframe) {
        frame.camera = cam;
      } else {
        // No keyframe: move every camera key so the whole take follows.
        for (final f in sequence.frames) {
          f.camera = cam;
        }
      }
    });
  }

  void clearCameraKeyframe() {
    mutate(() => frame.camera = null);
  }

  // -------------------------------------------------------------------------
  // Audio
  // -------------------------------------------------------------------------

  void addAudioCue(AudioCue cue) {
    mutate(() => frame.audio.add(cue));
  }

  void removeAudioCue(String cueId) {
    mutate(() => frame.audio.removeWhere((c) => c.id == cueId));
  }

  void setMusic(AudioTrack? track) {
    mutate(() => sequence.music = track);
  }

  // -------------------------------------------------------------------------
  // Sequences and movieclips
  // -------------------------------------------------------------------------

  Sequence addSequence() {
    return mutate(() {
      final s = Sequence(
        id: IdGen.next('seq'),
        name: 'Sequência ${project.sequences.length + 1}',
      );
      s.frames.add(Frame(id: IdGen.next('frame')));
      s.frames.add(Frame(id: IdGen.next('frame')));
      project.sequences.add(s);
      project.activeSequenceId = s.id;
      currentFrame = 0;
      return s;
    });
  }

  void deleteSequence(String id) {
    if (project.sequences.length <= 1) return;
    mutate(() {
      project.sequences.removeWhere((s) => s.id == id);
      if (project.activeSequenceId == id) {
        project.activeSequenceId = project.sequences.first.id;
        currentFrame = 0;
      }
    });
  }

  Movieclip? createMovieclipFromSelection(String name) {
    Movieclip? created;
    mutate(() {
      // Snapshot just the selected figure(s) as a reusable one-frame clip.
      final seq = Sequence(
        id: IdGen.next('seq'),
        name: name,
        fps: sequence.fps,
      );
      final f = Frame(id: IdGen.next('frame'));
      final l = Layer(id: IdGen.next('layer'), name: name);
      for (final layer in frame.layers) {
        for (final o in layer.objects) {
          if (o.kind == ObjectKind.figure)
            l.objects.add(o.duplicate(IdGen.next('obj')));
        }
      }
      f.layers.add(l);
      seq.frames.add(f);
      final clip = Movieclip(id: IdGen.next('clip'), name: name, sequence: seq);
      project.movieclips.add(clip);
      created = clip;
    });
    return created;
  }

  void deleteMovieclip(String id) {
    mutate(() {
      project.movieclips.removeWhere((c) => c.id == id);
      for (final seq in project.sequences) {
        for (final f in seq.frames) {
          for (final l in f.layers) {
            l.objects.removeWhere(
              (o) => o is MovieclipObject && o.clipId == id,
            );
          }
        }
      }
    });
  }

  // -------------------------------------------------------------------------
  // Scene queries used by the canvas
  // -------------------------------------------------------------------------

  ResolvedScene resolveAt(double position) => resolveScene(sequence, position);

  /// Flattened draw list honouring layer visibility and nesting.
  List<SceneObject> visibleObjects(ResolvedScene scene) {
    final hidden = <String>{};
    final opacity = <String, double>{};

    void walk(List<Layer> layers, double parentOpacity) {
      for (final l in layers) {
        if (!l.visible) {
          hidden.add(l.id);
          continue;
        }
        final eff = parentOpacity * l.opacity;
        opacity[l.id] = eff;
        for (final o in l.objects) {
          opacity[o.id] = eff * o.opacity;
        }
        final children = layers
            .where((c) => c.parentId == l.id)
            .toList(growable: false);
        if (children.isNotEmpty) walk(children, eff);
      }
    }

    walk(scene.layers, 1.0);

    final out = <SceneObject>[];
    for (final l in scene.layers) {
      if (hidden.contains(l.id)) continue;
      final lo = opacity[l.id] ?? 1.0;
      for (final o in l.objects) {
        if (!o.visible) continue;
        final eff = (opacity[o.id] ?? lo) * lo;
        out.add(eff == 1.0 ? o : o.withOpacity(eff));
      }
    }

    // Inline any movieclips so the painter only sees primitives.
    if (project.movieclips.isNotEmpty) {
      final position = scene.indexA + scene.t;
      return expandMovieclips(
        out,
        (id) => project.clipById(id)?.sequence,
        position,
        0,
      );
    }
    return out;
  }

  /// A layer is locked if it or any ancestor is locked.
  bool isLayerLocked(String layerId) {
    var cur = layerId;
    for (var i = 0; i < 16; i++) {
      Layer? found;
      for (final l in frame.layers) {
        if (l.id == cur) {
          found = l;
          break;
        }
      }
      if (found == null) return false;
      if (found.locked) return true;
      final p = found.parentId;
      if (p == null) return false;
      cur = p;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> flush() => _repo.saveNow(project);

  @override
  void dispose() {
    _repo.scheduleAutosave(project);
    super.dispose();
  }
}
