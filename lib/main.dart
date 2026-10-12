import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'data/project_repository.dart';
import 'l10n/strings.dart';
import 'ui/library_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const StickSceneApp());
}

class StickSceneApp extends StatefulWidget {
  const StickSceneApp({super.key});

  @override
  State<StickSceneApp> createState() => _StickSceneAppState();
}

class _StickSceneAppState extends State<StickSceneApp> {
  final ProjectRepository _repository = ProjectRepository();
  Locale _locale = const Locale('pt', 'BR');

  @override
  void dispose() {
    _repository.saveState.dispose();
    super.dispose();
  }

  void _setLocale(Locale locale) {
    setState(() => _locale = locale);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _repository,
      child: MaterialApp(
        title: 'StickScene',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        locale: _locale,
        supportedLocales: Strings.supportedLocales,
        localizationsDelegates: const [Strings.delegate],
        localeResolutionCallback: (device, supported) {
          // Fall back to the user's language when we ship it, otherwise the
          // author's first language (pt-BR).
          for (final l in supported) {
            if (l.languageCode == device?.languageCode) return l;
          }
          return const Locale('pt', 'BR');
        },
        onGenerateTitle: (context) => 'StickScene',
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          // Custom-drawn canvases cannot scale their own text, so a huge
          // system font would only break the editor layout.
          maxScaleFactor: 1.3,
          child: child ?? const SizedBox.shrink(),
        ),
        home: LibraryScreen(onLocaleChanged: _setLocale),
      ),
    );
  }
}
