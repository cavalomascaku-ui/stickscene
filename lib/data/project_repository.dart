import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/ids.dart';
import 'models.dart';
import 'project_codec.dart';

enum SaveState { idle, dirty, saving, saved, failed }

/// Where a project was loaded from. Used by the UI to warn when the user has
/// unsaved changes that only exist in memory.
enum LoadSource { primary, backup, empty }

class ProjectHandle {
  ProjectHandle({
    required this.project,
    required this.directory,
    required this.source,
  });

  final Project project;
  final Directory directory;
  final LoadSource source;

  File get jsonFile => File('${directory.path}/project.json');
  Directory get mediaDir => Directory('${directory.path}/media');
  Directory get backupDir => Directory('${directory.path}/backups');
}

/// Owns everything on disk for every project.
///
/// Design notes, because this is the part users actually care about:
///  * Writes are atomic - we write `project.json.tmp` then rename over the real
///    file. A crash mid-write can therefore never leave a half-written file.
///  * Before each save we snapshot the previous good file into `backups/`, and
///    rotate to at most [maxBackups]. That is what makes "undo a broken save"
///    possible even after the app is force-killed.
///  * [load] falls back to the newest decodable backup when the primary file
///    is missing or corrupt, so a bad save is an inconvenience, never data loss.
class ProjectRepository {
  ProjectRepository({
    this.maxBackups = 8,
    this.autosaveDelay = const Duration(seconds: 3),
  });

  final int maxBackups;
  final Duration autosaveDelay;

  Directory? _root;
  Timer? _debounce;

  SaveState _state = SaveState.idle;
  final List<void Function()> _stateListeners = <void Function()>[];

  /// Current save state. Observed via [addSaveStateListener].
  SaveState get saveState => _state;

  void addSaveStateListener(void Function() listener) =>
      _stateListeners.add(listener);

  void removeSaveStateListener(void Function() listener) =>
      _stateListeners.remove(listener);

  void _setState(SaveState next) {
    if (_state == next) return;
    _state = next;
    for (final l in List<void Function()>.of(_stateListeners)) {
      l();
    }
  }

  /// Human readable message for the last failure, shown in a snackbar.
  String? lastError;

  Future<Directory> _projectsRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/projects');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _root = dir;
  }

  Future<Directory> projectDir(String id) async {
    final root = await _projectsRoot();
    return Directory('${root.path}/$id');
  }

  // -------------------------------------------------------------------------
  // Library
  // -------------------------------------------------------------------------

  Future<List<ProjectSummary>> listProjects() async {
    final root = await _projectsRoot();
    final out = <ProjectSummary>[];
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final json = File('${entry.path}/project.json');
      if (!json.existsSync()) continue;
      try {
        out.add(ProjectCodec.peekSummary(json.readAsStringSync()));
      } catch (_) {
        // A corrupt project should still show up in the list rather than
        // silently vanish - the recovery path can still rescue it.
        try {
          final backups = Directory('${entry.path}/backups');
          final files = backups.existsSync()
              ? backups.listSync().whereType<File>().toList()
              : <File>[];
          files.sort((a, b) => b.path.compareTo(a.path));
          for (final f in files) {
            try {
              out.add(ProjectCodec.peekSummary(f.readAsStringSync()));
              break;
            } catch (_) {
              continue;
            }
          }
        } catch (_) {
          // give up on this one
        }
      }
    }
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  // -------------------------------------------------------------------------
  // Load
  // -------------------------------------------------------------------------

  Future<ProjectHandle> load(String id) async {
    final dir = await projectDir(id);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (!Directory('${dir.path}/media').existsSync()) {
      Directory('${dir.path}/media').createSync(recursive: true);
    }
    if (!Directory('${dir.path}/backups').existsSync()) {
      Directory('${dir.path}/backups').createSync(recursive: true);
    }

    final primary = File('${dir.path}/project.json');
    if (primary.existsSync()) {
      try {
        final p = ProjectCodec.decode(await primary.readAsString());
        return ProjectHandle(
          project: p,
          directory: dir,
          source: LoadSource.primary,
        );
      } catch (e) {
        lastError = 'project.json is unreadable, trying backups';
      }
    }

    // Fallback chain: newest readable backup wins.
    final backups = Directory('${dir.path}/backups');
    if (backups.existsSync()) {
      final files = backups.listSync().whereType<File>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files) {
        try {
          final p = ProjectCodec.decode(await f.readAsString());
          lastError = 'Recovered from backup taken ${f.uri.pathSegments.last}';
          return ProjectHandle(
            project: p,
            directory: dir,
            source: LoadSource.backup,
          );
        } catch (_) {
          continue;
        }
      }
    }

    // Nothing on disk. Start a fresh project rather than showing an error.
    final fresh = Project(id: id, name: 'Untitled');
    final seq = Sequence(id: IdGen.next('seq'), name: 'Sequence 1');
    fresh.sequences.add(seq);
    fresh.activeSequenceId = seq.id;
    return ProjectHandle(
      project: fresh,
      directory: dir,
      source: LoadSource.empty,
    );
  }

  /// Try every backup of a project. The recovery screen calls this so the user
  /// can pick which version to restore instead of blindly taking the newest.
  Future<List<ProjectSummary>> listRecoverableBackups(String id) async {
    final dir = await projectDir(id);
    final backups = Directory('${dir.path}/backups');
    if (!backups.existsSync()) return const [];
    final files = backups.listSync().whereType<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    final out = <ProjectSummary>[];
    for (final f in files) {
      try {
        final s = ProjectCodec.peekSummary(await f.readAsString());
        out.add(s);
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  Future<String> readBackupText(String id, String backupName) async {
    final dir = await projectDir(id);
    return File('${dir.path}/backups/$backupName').readAsString();
  }

  // -------------------------------------------------------------------------
  // Save
  // -------------------------------------------------------------------------

  /// Writes immediately. Call on app pause / exit.
  Future<void> saveNow(Project project) async {
    _debounce?.cancel();
    _debounce = null;
    await _write(project);
  }

  /// Coalesces bursts of edits into one write. This is what the editor calls on
  /// every mutation.
  void scheduleAutosave(Project project) {
    _setState(SaveState.dirty);
    _debounce?.cancel();
    _debounce = Timer(autosaveDelay, () => _write(project));
  }

  Future<void> _write(Project project) async {
    _setState(SaveState.saving);
    lastError = null;
    try {
      final dir = await projectDir(project.id);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final media = Directory('${dir.path}/media');
      if (!media.existsSync()) media.createSync(recursive: true);
      final backups = Directory('${dir.path}/backups');
      if (!backups.existsSync()) backups.createSync(recursive: true);

      final target = File('${dir.path}/project.json');

      // 1. Snapshot the current good file before overwriting it.
      if (target.existsSync()) {
        final stamp = DateTime.now()
            .toIso8601String()
            .replaceAll(':', '-')
            .replaceAll('.', '');
        await target.copy('${backups.path}/$stamp.json');
        _rotateBackups(backups);
      }

      // 2. Write to a temp file, then rename. Rename is atomic on the same
      //    filesystem, so a kill at any point leaves either the old file or the
      //    new one intact - never a truncated mix.
      final tmp = File('${dir.path}/project.json.tmp');
      final text = ProjectCodec.encode(project);
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(target.path);

      _setState(SaveState.saved);
    } catch (e) {
      _setState(SaveState.failed);
      lastError = 'Could not save: $e';
    }
  }

  void _rotateBackups(Directory backups) {
    final files = backups.listSync().whereType<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in files.skip(maxBackups)) {
      try {
        f.deleteSync();
      } catch (_) {
        // Non fatal: rotation is best-effort housekeeping.
      }
    }
  }

  // -------------------------------------------------------------------------
  // Media
  // -------------------------------------------------------------------------

  /// Copies an imported file into the project's media folder and returns the
  /// path to store in the JSON (relative, so the project folder stays movable).
  Future<String> importMedia(
    Project project,
    File source,
    String extension,
  ) async {
    final dir = await projectDir(project.id);
    final media = Directory('${dir.path}/media');
    if (!media.existsSync()) media.createSync(recursive: true);
    final name = '${IdGen.next('m')}$extension';
    final dest = File('${media.path}/$name');
    await source.copy(dest.path);
    return 'media/$name';
  }

  Future<File> resolveMedia(Project project, String relativePath) async {
    final dir = await projectDir(project.id);
    return File('${dir.path}/$relativePath');
  }

  Future<void> deleteProject(String id) async {
    final dir = await projectDir(id);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  Future<String> duplicateProject(String id, String newName) async {
    final src = await projectDir(id);
    final newId = IdGen.next('p');
    final dst = await projectDir(newId);
    if (src.existsSync()) _copyTree(src, dst);
    final json = File('${dst.path}/project.json');
    final project = ProjectCodec.decode(await json.readAsString());
    project
      ..id = newId
      ..name = newName
      ..modifiedAt = DateTime.now().millisecondsSinceEpoch;
    await saveNow(project);
    return newId;
  }

  /// Export a single self-contained file the user can move around freely.
  Future<File> exportProjectFile(Project project) async {
    final dir = await projectDir(project.id);
    final outDir = Directory('${dir.path}/exports');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final safe = project.name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final out = File(
      '${outDir.path}/${safe.isEmpty ? 'project' : safe}.stickscene.json',
    );
    await out.writeAsString(ProjectCodec.encode(project), flush: true);
    return out;
  }

  Future<void> importProjectFile(File file, String name) async {
    final project = ProjectCodec.decode(await file.readAsString());
    final id = IdGen.next('p');
    project
      ..id = id
      ..name = name
      ..modifiedAt = DateTime.now().millisecondsSinceEpoch;
    await saveNow(project);
  }

  static void _copyTree(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final entity in from.listSync(recursive: true)) {
      final rel = entity.path.substring(from.path.length + 1);
      if (entity is Directory) {
        Directory('${to.path}/$rel').createSync(recursive: true);
      } else if (entity is File) {
        final dest = File('${to.path}/$rel');
        dest.parent.createSync(recursive: true);
        entity.copySync(dest.path);
      }
    }
  }

  /// Wraps a project folder as a single zip so users can share a project that
  /// includes its media.
  Future<File> exportProjectBundle(Project project) async {
    final dir = await projectDir(project.id);
    final outDir = Directory('${dir.path}/exports');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final safe = project.name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final out = File('${outDir.path}/${safe.isEmpty ? 'project' : safe}.zip');
    if (out.existsSync()) out.deleteSync();
    await _zipDirectory(dir, out, skipDirName: 'exports');
    return out;
  }

  static Future<void> _zipDirectory(
    Directory dir,
    File out, {
    String? skipDirName,
  }) async {
    // Deliberately hand-rolled: pulling in the `archive` package would add a
    // large dependency for one screen, and STORED (no compression) entries are
    // valid zip and trivially readable by every platform.
    final sink = out.openWrite();
    final entries = <MapEntry<String, List<int>>>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(dir.path.length + 1);
      if (skipDirName != null && rel.startsWith('$skipDirName/')) continue;
      if (rel.endsWith('.tmp')) continue;
      entries.add(MapEntry(rel, entity.readAsBytesSync()));
    }

    final outBuf = BytesBuilder();
    final central = BytesBuilder();
    var offset = 0;

    for (final e in entries) {
      final nameBytes = utf8.encode(e.key);
      final data = e.value;
      final crc = _crc32(data);

      final local = BytesBuilder();
      local.add(<int>[0x50, 0x4b, 0x03, 0x04]); // local file header
      local.add(_u16(20)); // version needed
      local.add(_u16(0)); // flags
      local.add(_u16(0)); // method = stored
      local.add(_u16(0)); // time
      local.add(_u16(0)); // date
      local.add(_u32(crc));
      local.add(_u32(data.length));
      local.add(_u32(data.length));
      local.add(_u16(nameBytes.length));
      local.add(_u16(0));
      local.add(nameBytes);

      final localBytes = local.toBytes();
      outBuf.add(localBytes);
      outBuf.add(data);

      final cd = BytesBuilder();
      cd.add(<int>[0x50, 0x4b, 0x01, 0x02]); // central directory header
      cd.add(_u16(20)); // version made by
      cd.add(_u16(20)); // version needed
      cd.add(_u16(0)); // flags
      cd.add(_u16(0)); // method
      cd.add(_u16(0)); // time
      cd.add(_u16(0)); // date
      cd.add(_u32(crc));
      cd.add(_u32(data.length));
      cd.add(_u32(data.length));
      cd.add(_u16(nameBytes.length));
      cd.add(_u16(0)); // extra
      cd.add(_u16(0)); // comment
      cd.add(_u16(0)); // disk
      cd.add(_u16(0)); // internal attrs
      cd.add(_u32(0)); // external attrs
      cd.add(_u32(offset));
      cd.add(nameBytes);
      central.add(cd.toBytes());

      offset += localBytes.length + data.length;
    }

    final centralBytes = central.toBytes();
    outBuf.add(centralBytes);

    final end = BytesBuilder();
    end.add(<int>[0x50, 0x4b, 0x05, 0x06]);
    end.add(_u16(0));
    end.add(_u16(0));
    end.add(_u16(entries.length));
    end.add(_u16(entries.length));
    end.add(_u32(centralBytes.length));
    end.add(_u32(offset));
    end.add(_u16(0));
    outBuf.add(end.toBytes());

    sink.add(outBuf.toBytes());
    await sink.close();
  }

  static List<int> _u16(int v) => <int>[(v >> 8) & 0xFF, v & 0xFF];

  static List<int> _u32(int v) => <int>[
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];

  static final _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crc32(List<int> data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
