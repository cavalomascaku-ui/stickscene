import 'package:flutter/widgets.dart';

/// Hand-written localisation.
///
/// Deliberately not `flutter_localizations` + ARB: that needs `build_runner`
/// and a `generate: true` step, which means the project only compiles after a
/// codegen pass. For a two-language app this is a better trade - it builds the
/// moment you clone it.
///
/// Every key exists in both maps; [Strings.of] falls back to pt-BR and then to
/// the key itself, so a missing translation shows up as an obvious placeholder
/// rather than a blank button.
class Strings {
  const Strings(this.locale);

  final Locale locale;

  bool get isPt => locale.languageCode == 'pt';

  static const supported = <Locale>[Locale('pt', 'BR'), Locale('en')];

  static Strings of(BuildContext context) =>
      Localizations.of<Strings>(context, Strings) ??
      const Strings(Locale('pt', 'BR'));

  static const LocalizationsDelegate<Strings> delegate = _StringsDelegate();

  static List<Locale> get supportedLocales => supported;

  String t(String key) =>
      _values[locale.languageCode]?[key] ?? _values['pt']![key] ?? key;

  String call(String key) => t(key);

  /// Simple {0} style substitution, so translations can reorder placeholders.
  String f(String key, Map<String, Object?> args) {
    var s = t(key);
    args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    return s;
  }

  static const Map<String, Map<String, String>> _values = {
    'pt': {
      'appName': 'StickScene',
      'introTitle': 'V2 chegou',
      'introSubtitle': 'O mesmo stickman de sempre. Bem mais rápido.',
      'introBody':
          'Autosave a cada alteração, backup automático, áudio nos frames, '
          'câmera livre, texto, movieclips e uma interface que não tenta te '
          'ensinar nada.',
      'introStart': 'Começar',
      'introSkip': 'Pular',

      'menuNew': 'Novo projeto',
      'menuImport': 'Importar arquivo',
      'menuSettings': 'Ajustes',
      'menuExport': 'Exportar',
      'menuBack': 'Voltar',
      'menuDuplicate': 'Duplicar',
      'menuRename': 'Renomear',
      'menuDelete': 'Excluir',
      'menuCancel': 'Cancelar',
      'menuOk': 'OK',
      'menuSave': 'Salvar',
      'menuShare': 'Compartilhar',

      'emptyLibrary': 'Nenhum projeto ainda',
      'emptyLibraryHint': 'Toque em Novo projeto para começar.',
      'lastEdited': 'Editado',
      'frames': 'frames',
      'sequences': 'sequências',

      'saving': 'Salvando...',
      'saved': 'Salvo',
      'saveFailed': 'Falha ao salvar',
      'recoveredFromBackup':
          'O arquivo principal estava corrompido. Recuperei um backup.',

      'toolSelect': 'Selecionar',
      'toolFigure': 'Boneco',
      'toolPen': 'Desenhar',
      'toolText': 'Texto',
      'toolCircle': 'Círculo',
      'toolSprite': 'Imagem',
      'toolPan': 'Mover cena',

      'play': 'Tocar',
      'pause': 'Pausar',
      'stop': 'Parar',
      'loop': 'Repetir',
      'fps': 'FPS',
      'addFrame': '+ Frame',
      'duplicateFrame': 'Duplicar frame',
      'deleteFrame': 'Excluir frame',
      'undo': 'Desfazer',
      'redo': 'Refazer',
      'onionSkin': 'Casca de cebola',
      'simpleMode': 'Modo simples',
      'advancedMode': 'Modo avançado',

      'layers': 'Camadas',
      'addLayer': '+ Camada',
      'group': 'Agrupar',
      'ungroup': 'Desagrupar',
      'lock': 'Travar',
      'unlock': 'Destravar',
      'hide': 'Ocultar',
      'show': 'Mostrar',

      'pose': 'Pose',
      'poseStand': 'Parado',
      'poseWalk': 'Andar',
      'poseRun': 'Correr',
      'posePunch': 'Soco',
      'poseKick': 'Chute',
      'poseJump': 'Pulo',
      'poseFall': 'Caindo',
      'poseSit': 'Sentado',
      'poseLie': 'Deitado',
      'color': 'Cor',
      'thickness': 'Espessura',
      'joints': 'Mostrar juntas',

      'camera': 'Câmera',
      'cameraZoom': 'Zoom',
      'cameraRotate': 'Girar',
      'cameraCenter': 'Posição',
      'cameraReset': 'Câmera padrão',
      'cameraClearKey': 'Apagar chave da câmera',
      'cameraApplyAll': 'Aplicar em todos os frames',

      'audio': 'Áudio',
      'addSound': '+ Som',
      'addMusic': 'Música de fundo',
      'volume': 'Volume',
      'noSounds': 'Nenhum som neste frame',

      'background': 'Fundo',
      'backgroundColor': 'Cor do fundo',
      'backgroundImage': 'Imagem de fundo',
      'chooseImage': 'Escolher imagem',
      'removeImage': 'Remover imagem',

      'exportGif': 'GIF animado',
      'exportMp4': 'Vídeo MP4 com som',
      'exportMp4Unavailable': 'MP4 só funciona no Android.',
      'exportPreparingAudio': 'Preparando áudio...',
      'exportVideoDone': 'MP4 pronto com {0}s de áudio',
      'exportSheet': 'Sprite sheet (PNG)',
      'exportSequence': 'Sequência de PNG',
      'exportSize': 'Tamanho',
      'exporting': 'Exportando...',
      'exportDone': 'Exportado para',
      'exportNoAudio': 'GIF não tem áudio.',

      'textTool': 'Texto',
      'textPlaceholder': 'Escreva aqui',
      'bubble': 'Balão',
      'bubbleNone': 'Sem balão',
      'bubbleRounded': 'Redondo',
      'bubbleTail': 'Com rabinho',

      'movieclip': 'Movieclip',
      'createClip': 'Criar movieclip',
      'noClips': 'Nenhum movieclip',

      'settingsTitle': 'Ajustes',
      'language': 'Idioma',
      'simpleModeHelp': 'Modo simples esconde timeline e camadas. Dá pra voltar quando quiser.',
      'about': 'Sobre',
      'aboutBody': 'StickScene V2. Projeto aberto, sem anúncios e sem conta.',

      'name': 'Nome',
      'deleteConfirm': 'Excluir isso?',
      'deleteProjectWarn': 'Essa ação não pode ser desfeita.',
      'genericError': 'Algo deu errado',
      'retry': 'Tentar de novo',
    },
    'en': {
      'appName': 'StickScene',
      'introTitle': 'V2 is here',
      'introSubtitle': 'The same stick figure. A lot faster.',
      'introBody':
          'Autosave on every change, automatic backups, per-frame audio, a '
          'free camera, text layers, movieclips, and an interface that does not '
          'try to teach you anything.',
      'introStart': 'Start',
      'introSkip': 'Skip',

      'menuNew': 'New project',
      'menuImport': 'Import file',
      'menuSettings': 'Settings',
      'menuExport': 'Export',
      'menuBack': 'Back',
      'menuDuplicate': 'Duplicate',
      'menuRename': 'Rename',
      'menuDelete': 'Delete',
      'menuCancel': 'Cancel',
      'menuOk': 'OK',
      'menuSave': 'Save',
      'menuShare': 'Share',

      'emptyLibrary': 'No projects yet',
      'emptyLibraryHint': 'Tap New project to begin.',
      'lastEdited': 'Edited',
      'frames': 'frames',
      'sequences': 'sequences',

      'saving': 'Saving...',
      'saved': 'Saved',
      'saveFailed': 'Save failed',
      'recoveredFromBackup':
          'The main file was corrupted. A backup was recovered.',

      'toolSelect': 'Select',
      'toolFigure': 'Figure',
      'toolPen': 'Draw',
      'toolText': 'Text',
      'toolCircle': 'Circle',
      'toolSprite': 'Image',
      'toolPan': 'Pan scene',

      'play': 'Play',
      'pause': 'Pause',
      'stop': 'Stop',
      'loop': 'Loop',
      'fps': 'FPS',
      'addFrame': '+ Frame',
      'duplicateFrame': 'Duplicate frame',
      'deleteFrame': 'Delete frame',
      'undo': 'Undo',
      'redo': 'Redo',
      'onionSkin': 'Onion skin',
      'simpleMode': 'Simple mode',
      'advancedMode': 'Advanced mode',

      'layers': 'Layers',
      'addLayer': '+ Layer',
      'group': 'Group',
      'ungroup': 'Ungroup',
      'lock': 'Lock',
      'unlock': 'Unlock',
      'hide': 'Hide',
      'show': 'Show',

      'pose': 'Pose',
      'poseStand': 'Stand',
      'poseWalk': 'Walk',
      'poseRun': 'Run',
      'posePunch': 'Punch',
      'poseKick': 'Kick',
      'poseJump': 'Jump',
      'poseFall': 'Fall',
      'poseSit': 'Sit',
      'poseLie': 'Lie',
      'color': 'Colour',
      'thickness': 'Thickness',
      'joints': 'Show joints',

      'camera': 'Camera',
      'cameraZoom': 'Zoom',
      'cameraRotate': 'Rotate',
      'cameraCenter': 'Position',
      'cameraReset': 'Reset camera',
      'cameraClearKey': 'Clear camera key',
      'cameraApplyAll': 'Apply to every frame',

      'audio': 'Audio',
      'addSound': '+ Sound',
      'addMusic': 'Background music',
      'volume': 'Volume',
      'noSounds': 'No sounds on this frame',

      'background': 'Background',
      'backgroundColor': 'Background colour',
      'backgroundImage': 'Background image',
      'chooseImage': 'Choose image',
      'removeImage': 'Remove image',

      'exportGif': 'Animated GIF',
      'exportMp4': 'MP4 video with sound',
      'exportMp4Unavailable': 'MP4 export only works on Android.',
      'exportPreparingAudio': 'Preparing audio...',
      'exportVideoDone': 'MP4 ready with {0}s of audio',
      'exportSheet': 'Sprite sheet (PNG)',
      'exportSequence': 'PNG sequence',
      'exportSize': 'Size',
      'exporting': 'Exporting...',
      'exportDone': 'Exported to',
      'exportNoAudio': 'GIF cannot carry audio.',

      'textTool': 'Text',
      'textPlaceholder': 'Type here',
      'bubble': 'Bubble',
      'bubbleNone': 'No bubble',
      'bubbleRounded': 'Rounded',
      'bubbleTail': 'With tail',

      'movieclip': 'Movieclip',
      'createClip': 'Create movieclip',
      'noClips': 'No movieclips',

      'settingsTitle': 'Settings',
      'language': 'Language',
      'simpleModeHelp': 'Simple mode hides the timeline and layers. You can switch back any time.',
      'about': 'About',
      'aboutBody': 'StickScene V2. Open project, no ads and no account.',

      'name': 'Name',
      'deleteConfirm': 'Delete this?',
      'deleteProjectWarn': 'This cannot be undone.',
      'genericError': 'Something went wrong',
      'retry': 'Try again',
    },
  };
}

class _StringsDelegate extends LocalizationsDelegate<Strings> {
  const _StringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      Strings._values.containsKey(locale.languageCode);

  @override
  Future<Strings> load(Locale locale) async => Strings(locale);

  @override
  bool shouldReload(_StringsDelegate old) => false;
}
