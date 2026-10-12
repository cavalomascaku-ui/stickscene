import 'dart:math';

/// Short, collision-resistant ids. Time-prefixed so that sorting by id roughly
/// sorts by creation time, which the timeline and library lists rely on.
class IdGen {
  IdGen._();

  static final Random _rng = Random();
  static int _counter = 0;

  static String next(String prefix) {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final c = (_counter++).toRadixString(36).padLeft(3, '0');
    final r = _rng.nextInt(0x3fffff).toRadixString(36).padLeft(5, '0');
    return '$prefix-$ts-$c$r';
  }
}
