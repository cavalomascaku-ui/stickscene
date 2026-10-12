import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/ids.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/project_codec.dart';
import '../data/project_repository.dart';
import '../l10n/strings.dart';
import 'editor_screen.dart';
import 'intro_screen.dart';

/// Project picker. Also the screen that surfaces the autosave/backup state, so
/// the user always knows whether their work is on disk.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.onLocaleChanged});

  final void Function(Locale) onLocaleChanged;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _introSeenKey = 'stickscene_intro_seen_v2';

  bool _showIntro = false;
  bool _loading = true;
  List<ProjectSummary> _projects = [];

  ProjectRepository get _repo => context.read<ProjectRepository>();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final prefs = await _prefs();
    final seen = prefs.getBool(_introSeenKey) ?? false;
    if (!mounted) return;
    if (!seen) {
      setState(() => _showIntro = true);
      await prefs.setBool(_introSeenKey, true);
    }
    await _refresh();
  }

  // Stored outside SharedPreferences so the app carries no extra plugin; the
  // intro flag only needs to survive a restart.
  Future<Map<String, bool>> _prefs() async {
    return _Prefs.instance;
  }

  Future<void> _refresh() async {
    final list = await _repo.listProjects();
    if (!mounted) return;
    setState(() {
      _projects = list;
      _loading = false;
    });
  }

  Future<void> _createProject() async {
    final s = Strings.of(context);
    final name = await _askForName(
      context,
      title: s.t('menuNew'),
      initial: 'Meu projeto',
    );
    if (name == null || !mounted) return;

    final id = IdGen.next('p');
    final project = Project(id: id, name: name);
    final seq = Sequence(id: IdGen.next('seq'), name: 'Sequence 1');
    seq.frames
      ..add(Frame(id: IdGen.next('frame')))
      ..add(Frame(id: IdGen.next('frame')));
    seq.frames[0].layers.add(Layer(id: IdGen.next('layer'), name: 'Camada 1'));
    seq.frames[1].layers.add(Layer(id: IdGen.next('layer'), name: 'Camada 1'));
    project.sequences.add(seq);
    project.activeSequenceId = seq.id;

    await _repo.saveNow(project);
    await _refresh();
    if (!mounted) return;
    await _open(id);
  }

  Future<void> _open(String id) async {
    final handle = await _repo.load(id);
    if (!mounted) return;
    if (handle.source == LoadSource.backup && _repo.lastError != null) {
      _snack(_repo.lastError!);
    }
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => EditorScreen(handle: handle)));
    await _refresh();
  }

  Future<void> _duplicate(ProjectSummary summary) async {
    await _repo.duplicateProject(summary.id, '${summary.name} copia');
    await _refresh();
  }

  Future<void> _rename(ProjectSummary summary) async {
    final s = Strings.of(context);
    final name = await _askForName(
      context,
      title: s.t('menuRename'),
      initial: summary.name,
    );
    if (name == null || name.trim().isEmpty) return;
    final handle = await _repo.load(summary.id);
    handle.project.name = name.trim();
    await _repo.saveNow(handle.project);
    await _refresh();
  }

  Future<void> _delete(ProjectSummary summary) async {
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('deleteConfirm')),
        content: Text(s.t('deleteProjectWarn')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('menuCancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: paletteOf(ctx).danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('menuDelete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.deleteProject(summary.id);
    await _refresh();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = paletteOf(context);

    if (_showIntro) {
      return IntroScreen(onDone: () => setState(() => _showIntro = false));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('appName')),
        actions: [
          IconButton(
            tooltip: s.t('menuSettings'),
            icon: const Icon(Icons.tune_rounded),
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createProject,
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text(s.t('menuNew')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
          ? _emptyState(s, p)
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: _projects.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _ProjectCard(
                  summary: _projects[i],
                  onTap: () => _open(_projects[i].id),
                  onDuplicate: () => _duplicate(_projects[i]),
                  onRename: () => _rename(_projects[i]),
                  onDelete: () => _delete(_projects[i]),
                ),
              ),
            ),
    );
  }

  Widget _emptyState(Strings s, AppPalette p) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_motion_outlined, size: 56, color: p.textDim),
          const SizedBox(height: 16),
          Text(
            s.t('emptyLibrary'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.t('emptyLibraryHint'),
            textAlign: TextAlign.center,
            style: TextStyle(color: p.textDim),
          ),
        ],
      ),
    ),
  );

  Future<void> _openSettings() async {
    final s = Strings.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.language_rounded),
              title: Text(s.t('language')),
              trailing: Text(Strings.of(ctx).isPt ? 'Português' : 'English'),
              onTap: () {
                Navigator.pop(ctx);
                widget.onLocaleChanged(
                  Strings.of(context).isPt
                      ? const Locale('en')
                      : const Locale('pt', 'BR'),
                );
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(s.t('about')),
              subtitle: Text(s.t('aboutBody')),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.summary,
    required this.onTap,
    required this.onDuplicate,
    required this.onRename,
    required this.onDelete,
  });

  final ProjectSummary summary;
  final VoidCallback onTap;
  final VoidCallback onDuplicate;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = paletteOf(context);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 58,
                decoration: BoxDecoration(
                  color: p.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.border),
                ),
                child: CustomPaint(painter: _ThumbPainter(p.accent)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${summary.frameCount} ${s.t('frames')} · '
                      '${summary.sequenceCount} ${s.t('sequences')}'
                      '${summary.fps > 0 ? ' · ${summary.fps} fps' : ''}',
                      style: TextStyle(fontSize: 13, color: p.textDim),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${s.t('lastEdited')} ${_relative(summary.modifiedAt)}',
                      style: TextStyle(fontSize: 12, color: p.textDim),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: p.textDim),
                onSelected: (v) {
                  switch (v) {
                    case 'dup':
                      onDuplicate();
                    case 'rename':
                      onRename();
                    case 'del':
                      onDelete();
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    value: 'dup',
                    child: Row(
                      children: [
                        const Icon(Icons.copy_rounded, size: 18),
                        const SizedBox(width: 10),
                        Text(s.t('menuDuplicate')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_rounded, size: 18),
                        const SizedBox(width: 10),
                        Text(s.t('menuRename')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'del',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: p.danger,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          s.t('menuDelete'),
                          style: TextStyle(color: p.danger),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final cx = size.width / 2;
    canvas.drawCircle(Offset(cx, size.height * 0.28), 5.5, stroke);
    canvas.drawLine(
      Offset(cx, size.height * 0.38),
      Offset(cx, size.height * 0.62),
      stroke,
    );
    canvas.drawLine(
      Offset(cx, size.height * 0.44),
      Offset(cx - 8, size.height * 0.54),
      stroke,
    );
    canvas.drawLine(
      Offset(cx, size.height * 0.44),
      Offset(cx + 8, size.height * 0.54),
      stroke,
    );
    canvas.drawLine(
      Offset(cx, size.height * 0.62),
      Offset(cx - 7, size.height * 0.8),
      stroke,
    );
    canvas.drawLine(
      Offset(cx, size.height * 0.62),
      Offset(cx + 7, size.height * 0.8),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter old) => old.color != color;
}

String _relative(int millisSinceEpoch) {
  final d = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(millisSinceEpoch),
  );
  if (d.inMinutes < 1) return 'agora';
  if (d.inHours < 1) return '${d.inMinutes} min';
  if (d.inDays < 1) return '${d.inHours} h';
  if (d.inDays < 7) return '${d.inDays} d';
  return '${(d.inDays / 7).floor()} sem';
}

Future<String?> _askForName(
  BuildContext context, {
  required String title,
  required String initial,
}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: Strings.of(ctx).t('name')),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(Strings.of(ctx).t('menuCancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: Text(Strings.of(ctx).t('menuSave')),
        ),
      ],
    ),
  );
}

/// Tiny in-memory flag store. Replaced by real preferences if the app ever
/// needs more than "has the intro been seen".
class _Prefs {
  static final Map<String, bool> _data = <String, bool>{};
  static const _Prefs instance = _Prefs();
  bool getBool(String key) => _data[key];
  Future<void> setBool(String key, bool value) async => _data[key] = value;
}

/// Exposed for the editor screen's "open" path.
typedef OpenProject = Future<void> Function(String id);

/// Helper used by tests and the editor to encode a project without a repo.
String encodeForDebug(Project p) => ProjectCodec.encode(p);
