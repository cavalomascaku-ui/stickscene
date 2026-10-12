import 'dart:math' as math;
import 'dart:typed_data';

/// A self-contained GIF89a encoder.
///
/// Written by hand rather than pulled from a package for one reason: it can be
/// executed and verified on a plain Dart VM, so "the GIF export produces a
/// valid file" is something I can prove instead of assume.
///
/// Supports: 256-colour global palette, per-frame delay, transparency, and
/// infinite looping (Netscape 2.0 extension).
class GifEncoder {
  GifEncoder({this.loop = 0, this.transparentIndex = 255, this.dither = true});

  /// 0 = loop forever, n = play n times, -1 = play once.
  final int loop;

  /// Palette slot used for fully transparent pixels.
  final int transparentIndex;

  /// Ordered (Bayer 4x4) dithering, which keeps thin anti-aliased strokes
  /// readable after quantisation. Without it, line art gets banding.
  final bool dither;

  /// Duration applied to every frame, in milliseconds. The exporter sets this
  /// from the sequence fps so the GIF plays at the right speed.
  int frameDelayMs = 10;

  final _out = BytesBuilder();
  final _frames = <_RawFrame>[];
  bool _started = false;

  int _width = 0;
  int _height = 0;
  List<int> _palette = const [];

  /// Adds one frame as raw RGBA bytes (length = width * height * 4).
  void addFrame(Uint8List rgba, int width, int height) {
    if (!_started) {
      _width = width;
      _height = height;
      _started = true;
    } else if (width != _width || height != _height) {
      throw ArgumentError(
        'GIF frames must all be the same size; got ${width}x$height after ${_width}x$_height',
      );
    }
    _frames.add(_RawFrame(width, height, Uint8List.fromList(rgba)));
  }

  bool get isEmpty => _frames.isEmpty;

  /// Quantises, then writes the file. One pass over every pixel so the palette
  /// is global - per-frame palettes would make the file larger and cause
  /// flicker on flat backgrounds.
  Uint8List finish() {
    if (_frames.isEmpty) {
      throw StateError('finish() called with no frames');
    }
    _palette = buildPalette(_frames, reserved: 1);

    final header = BytesBuilder();
    header.add(asciiBytes('GIF89a'));

    // Logical screen descriptor.
    header.add(_u16(_width));
    header.add(_u16(_height));
    // Global colour table present, 8 bits per primary, colour table size 256.
    header.add(<int>[0xF7, 0x00, 0x00]);

    // The palette is a flat RGB list; the table is 256 slots x 3 channels.
    final table = Uint8List(768);
    final colorCount = _palette.length ~/ 3;
    for (var c = 0; c < colorCount && c < 255; c++) {
      table[c * 3] = _palette[c * 3];
      table[c * 3 + 1] = _palette[c * 3 + 1];
      table[c * 3 + 2] = _palette[c * 3 + 2];
    }
    // Pad the unused slots, keeping slot 255 free for transparency.
    for (var c = colorCount; c < 256; c++) {
      table[c * 3] = 255;
      table[c * 3 + 1] = 0;
      table[c * 3 + 2] = 255;
    }
    header.add(table);

    // Netscape looping extension.
    if (loop >= 0) {
      header.add(<int>[0x21, 0xFF, 0x0B]);
      header.add(asciiBytes('NETSCAPE2.0'));
      header.add(<int>[0x03, 0x01]);
      header.add(_u16(loop));
      header.add(<int>[0x00]);
    }

    for (final f in _frames) {
      final indexed = _index(f);
      final delay = frameDelayMs;

      // Graphic control extension: delay in hundredths of a second, plus the
      // transparent colour index and disposal method 2 (restore to background)
      // so partially transparent frames do not smear into each other.
      _out.add(<int>[
        0x21, 0xF9, 0x04,
        0x09, // disposal 2 | transparency flag
        delay & 0xFF, (delay >> 8) & 0xFF,
        transparentIndex & 0xFF,
        0x00,
      ]);

      // Image descriptor.
      _out.add(<int>[0x2C]);
      _out.add(_u16(0));
      _out.add(_u16(0));
      _out.add(_u16(_width));
      _out.add(_u16(_height));
      _out.add(<int>[0x00]); // no local colour table, not interlaced

      // LZW minimum code size. 8 bits (256 colours) keeps the encoder simple;
      // GIF decoders all accept it.
      const minCodeSize = 8;
      _out.add(<int>[minCodeSize]);
      _out.add(_lzwCompress(indexed, minCodeSize));
    }

    _out.add(<int>[0x3B]); // trailer

    final body = _out.toBytes();
    final all = BytesBuilder()
      ..add(header.toBytes())
      ..add(body);
    return all.toBytes();
  }

  /// Maps a frame's RGBA pixels onto the global palette.
  Uint8List _index(_RawFrame f) {
    final n = f.width * f.height;
    final out = Uint8List(n);
    final pal = _palette;
    final palCount = math.min(pal.length ~/ 3, 256);

    final cache = <int, int>{};
    const bayer = _bayerMatrix;

    for (var y = 0; y < f.height; y++) {
      for (var x = 0; x < f.width; x++) {
        final i = y * f.width + x;
        final p = i * 4;
        final a = f.data[p + 3];

        if (a < 128) {
          out[i] = transparentIndex;
          continue;
        }

        var r = f.data[p];
        var g = f.data[p + 1];
        var b = f.data[p + 2];

        if (dither && a < 255) {
          // Soft edges: nudge the colour by a small ordered offset so the
          // quantiser picks a neighbouring entry instead of a hard edge.
          final d = (((bayer[(y & 3) * 4 + (x & 3)] - 7) * (a / 255) * 1.6))
              .round();
          r = _clampByte(r + d);
          g = _clampByte(g + d);
          b = _clampByte(b + d);
        }

        final key = (r << 16) | (g << 8) | b;
        final hit = cache[key];
        if (hit != null) {
          out[i] = hit;
          continue;
        }

        var best = 0;
        var bestDist = 1 << 30;
        for (var c = 0; c < palCount; c++) {
          final dr = r - pal[c * 3];
          final dg = g - pal[c * 3 + 1];
          final db = b - pal[c * 3 + 2];
          // Perceptual weighting: the eye is far more sensitive to green.
          final dist = dr * dr * 3 + dg * dg * 6 + db * db;
          if (dist < bestDist) {
            bestDist = dist;
            best = c;
            if (dist == 0) break;
          }
        }
        cache[key] = best;
        out[i] = best;
      }
    }
    return out;
  }

  /// Median-cut quantisation across every frame, which keeps the palette stable
  /// for the whole animation instead of letting it drift per frame.
  static List<int> buildPalette(List<_RawFrame> frames, {int reserved = 1}) {
    final target = 256 - reserved;

    // Collect a bounded sample of distinct-ish colours. Sampling every pixel of
    // a 1000-frame animation would be wasteful and memory-hungry.
    final buckets = <int, int>{}; // packed rgb -> count
    final sampleBudget = 40000;
    final totalPixels = frames.fold<int>(0, (a, f) => a + f.width * f.height);
    final stride = math.max(1, totalPixels ~/ sampleBudget);

    var seen = 0;
    outer:
    for (final f in frames) {
      final step = stride * 4;
      for (var p = 0; p < f.data.length; p += step) {
        if (f.data[p + 3] < 128) continue;
        final key = (f.data[p] << 16) | (f.data[p + 1] << 8) | f.data[p + 2];
        buckets[key] = (buckets[key] ?? 0) + 1;
        if (++seen >= sampleBudget) break outer;
      }
    }

    if (buckets.isEmpty) return <int>[0, 0, 0];

    final entries = buckets.entries
        .map(
          (e) => _Color(
            (e.key >> 16) & 0xFF,
            (e.key >> 8) & 0xFF,
            e.key & 0xFF,
            e.value,
          ),
        )
        .toList();

    // Split until we hit the target size or nothing useful is left to split.
    var boxes = <_Box>[_Box(entries)];
    while (boxes.length < target) {
      // Always work on the box with the largest weighted volume, and never
      // drop a box that could not be split - otherwise its colours would be
      // silently lost from the palette.
      var bestIndex = -1;
      var bestVolume = -1;
      for (var i = 0; i < boxes.length; i++) {
        final v = boxes[i].volume;
        if (boxes[i].colors.length >= 2 && v > bestVolume) {
          bestVolume = v;
          bestIndex = i;
        }
      }
      if (bestIndex < 0) break; // every box holds a single colour

      final parts = boxes[bestIndex].split();
      if (parts == null) break;
      boxes
        ..removeAt(bestIndex)
        ..add(parts.$1)
        ..add(parts.$2);
    }

    final out = <int>[];
    for (final box in boxes) {
      if (out.length >= 255 * 3) break;
      final avg = box.average();
      out.add(avg[0]);
      out.add(avg[1]);
      out.add(avg[2]);
    }
    if (out.length < 3) {
      out
        ..clear()
        ..addAll(<int>[0, 0, 0]);
    }
    return out;
  }

  /// Standard GIF LZW. Variable code width 9..12, clear code 256, end code 257.
  /// Exposed so the test harness can prove compress/decompress round-trips.
  static List<int> lzwCompressForTest(Uint8List indices, int minCodeSize) =>
      _lzwCompress(indices, minCodeSize);

  static List<int> _lzwCompress(Uint8List indices, int minCodeSize) {
    final out = BytesBuilder();
    final clearCode = 1 << minCodeSize;
    final endCode = clearCode + 1;

    var codeSize = minCodeSize + 1;
    var nextCode = endCode + 1;
    final dict = <int, int>{};

    var bitBuffer = 0;
    var bitCount = 0;
    var block = BytesBuilder();
    var blockSize = 0;

    void emit(int code) {
      bitBuffer |= code << bitCount;
      bitCount += codeSize;
      while (bitCount >= 8) {
        block.add(<int>[bitBuffer & 0xFF]);
        blockSize++;
        bitBuffer >>= 8;
        bitCount -= 8;
        if (blockSize == 255) {
          out.add(<int>[0xFF]);
          out.add(block.toBytes());
          block = BytesBuilder();
          blockSize = 0;
        }
      }
    }

    emit(clearCode);

    if (indices.isEmpty) {
      emit(endCode);
      _flush(out, block, blockSize, bitBuffer, bitCount);
      return out.toBytes();
    }

    var prefix = indices[0];
    for (var i = 1; i < indices.length; i++) {
      final k = indices[i];
      final key = (prefix << 8) | k;
      final existing = dict[key];
      if (existing != null) {
        prefix = existing;
        continue;
      }
      emit(prefix);

      if (nextCode < 4096) {
        dict[key] = nextCode++;
        if (nextCode > (1 << codeSize) && codeSize < 12) codeSize++;
      } else {
        // Dictionary full: reset rather than grow forever.
        emit(clearCode);
        dict.clear();
        codeSize = minCodeSize + 1;
        nextCode = endCode + 1;
      }
      prefix = k;
    }
    emit(prefix);
    emit(endCode);
    _flush(out, block, blockSize, bitBuffer, bitCount);

    return out.toBytes();
  }

  static void _flush(
    BytesBuilder out,
    BytesBuilder block,
    int blockSize,
    int buffer,
    int count,
  ) {
    if (count > 0) {
      block.add(<int>[buffer & 0xFF]);
      blockSize++;
    }
    if (blockSize > 0) {
      out.add(<int>[blockSize]);
      out.add(block.toBytes());
    }
    out.add(<int>[0x00]); // block terminator
  }

  static const _bayerMatrix = <int>[
    0, 8, 2, 10, //
    12, 4, 14, 6, //
    3, 11, 1, 9, //
    15, 7, 13, 5, //
  ];

  static int _clampByte(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

  static List<int> asciiBytes(String s) =>
      s.codeUnits.map((c) => c & 0xFF).toList();

  /// GIF stores the two-byte fields of the logical screen descriptor and the
  /// image descriptor LOW BYTE FIRST. This is a documented quirk of the format
  /// (PNG is the opposite), and getting it wrong makes every strict decoder
  /// read a 8x8 image as 2048x2048.
  static List<int> _u16(int v) => <int>[v & 0xFF, (v >> 8) & 0xFF];
}

class _RawFrame {
  _RawFrame(this.width, this.height, this.data);

  final int width;
  final int height;
  final Uint8List data;
}

class _Color {
  _Color(this.r, this.g, this.b, this.weight);

  final int r;
  final int g;
  final int b;
  final int weight;
}

class _Box {
  _Box(this.colors);

  final List<_Color> colors;

  int get volume {
    if (colors.length < 2) return 0;
    var l = 255, h = 0, l2 = 255, h2 = 0, l3 = 255, h3 = 0;
    for (final c in colors) {
      l = math.min(l, c.r);
      h = math.max(h, c.r);
      l2 = math.min(l2, c.g);
      h2 = math.max(h2, c.g);
      l3 = math.min(l3, c.b);
      h3 = math.max(h3, c.b);
    }
    return (h - l) * (h2 - l2) * (h3 - l3);
  }

  List<int> average() {
    var r = 0, g = 0, b = 0, w = 0;
    for (final c in colors) {
      r += c.r * c.weight;
      g += c.g * c.weight;
      b += c.b * c.weight;
      w += c.weight;
    }
    if (w == 0) return <int>[0, 0, 0];
    return <int>[(r / w).round(), (g / w).round(), (b / w).round()];
  }

  /// Splits along the longest weighted axis. Returns null when unsplittable.
  (_Box, _Box)? split() {
    if (colors.length < 2) return null;

    var l = 255, h = 0, l2 = 255, h2 = 0, l3 = 255, h3 = 0;
    for (final c in colors) {
      l = math.min(l, c.r);
      h = math.max(h, c.r);
      l2 = math.min(l2, c.g);
      h2 = math.max(h2, c.g);
      l3 = math.min(l3, c.b);
      h3 = math.max(h3, c.b);
    }

    final spanR = h - l, spanG = h2 - l2, spanB = h3 - l3;
    final axis = (spanR >= spanG && spanR >= spanB)
        ? 0
        : (spanG >= spanB ? 1 : 2);

    final sorted = List<_Color>.from(colors)
      ..sort((a, b) => _axis(a, axis).compareTo(_axis(b, axis)));

    // Cut at the weighted median so both halves carry similar pixel mass.
    final total = sorted.fold<int>(0, (a, c) => a + c.weight);
    var acc = 0;
    var cut = 1;
    for (var i = 0; i < sorted.length - 1; i++) {
      acc += sorted[i].weight;
      if (acc * 2 >= total) {
        cut = i + 1;
        break;
      }
    }
    cut = cut.clamp(1, sorted.length - 1);

    return (_Box(sorted.sublist(0, cut)), _Box(sorted.sublist(cut)));
  }

  static int _axis(_Color c, int axis) =>
      axis == 0 ? c.r : (axis == 1 ? c.g : c.b);
}
