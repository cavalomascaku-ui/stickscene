// GIF encoder verification.
//
// Two layers of checking:
//  1. In-process: LZW compress/decompress round-trip and file structure.
//  2. Out-of-process: writes a real .gif that test/verify_gif.py opens with
//     PIL - an independent decoder - and compares pixel by pixel.
//
// Run:  dart run test/gif_smoke.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/export/gif_encoder.dart';

int _failures = 0;
int _checks = 0;

void check(String label, bool ok) {
  _checks++;
  if (!ok) {
    _failures++;
    print('  FAIL  $label');
  } else {
    print('  ok    $label');
  }
}

/// Builds RGBA pixels: dark background, a filled disc that moves per frame.
Uint8List makeFrame(
  int size,
  double cx,
  double cy,
  double r, {
  int bg = 0xFF1E1E28,
  int fg = 0xFFFF3B30,
}) {
  final data = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final p = (y * size + x) * 4;
      final inside = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) <= r;
      data[p] = inside ? ((fg >> 16) & 0xFF) : ((bg >> 16) & 0xFF);
      data[p + 1] = inside ? ((fg >> 8) & 0xFF) : ((bg >> 8) & 0xFF);
      data[p + 2] = inside ? (fg & 0xFF) : (bg & 0xFF);
      data[p + 3] = 0xFF;
    }
  }
  return data;
}

/// Strips the GIF sub-block framing ([size][data]... terminated by 0x00) so the
/// decompressor below sees a continuous byte stream. Also verifies that the
/// framing itself is well formed.
List<int> stripSubBlocks(List<int> framed) {
  final out = <int>[];
  var i = 0;
  var blocks = 0;
  while (i < framed.length) {
    final size = framed[i++];
    if (size == 0) break;
    if (i + size > framed.length) {
      throw StateError(
        'sub-block claims $size bytes, only ${framed.length - i} left',
      );
    }
    for (var k = 0; k < size; k++) {
      out.add(framed[i + k]);
    }
    i += size;
    blocks++;
  }
  // i now sits just past the 0x00 terminator, so it must equal the length.
  if (i != framed.length) {
    throw StateError('expected a 0x00 terminator at the very end');
  }
  if (blocks == 0) throw StateError('no sub-blocks found');
  return out;
}

/// Reference GIF LZW decompressor, used only to prove the compressor.
List<int> lzwDecode(List<int> framedBytes, int minCodeSize) {
  final bytes = stripSubBlocks(framedBytes);
  final clear = 1 << minCodeSize;
  final end = clear + 1;
  List<List<int>> reset() => <List<int>>[
    for (var i = 0; i < clear; i++) <int>[i],
    <int>[],
    <int>[],
  ];

  var dict = reset();
  var codeSize = minCodeSize + 1;
  var next = end + 1;
  final out = <int>[];
  var bitPos = 0;
  List<int>? prev;

  while (bitPos + codeSize <= bytes.length * 8) {
    var code = 0;
    for (var i = 0; i < codeSize; i++) {
      code |= ((bytes[bitPos >> 3] >> (bitPos & 7)) & 1) << i;
      bitPos++;
    }

    if (code == clear) {
      dict = reset();
      codeSize = minCodeSize + 1;
      next = end + 1;
      prev = null;
      continue;
    }
    if (code == end) break;

    List<int> entry;
    if (code < dict.length && dict[code].isNotEmpty) {
      entry = dict[code];
    } else if (prev != null) {
      entry = <int>[...prev, prev[0]];
    } else {
      break;
    }
    out.addAll(entry);

    if (prev != null) {
      dict.add(<int>[...prev, entry[0]]);
      next++;
      // giflib's decoder rule: widen when the next free code reaches a full
      // power of two. (The *encoder* uses `>`, one step later - verified
      // against ImageMagick in both directions.)
      if (next == (1 << codeSize) && codeSize < 12) codeSize++;
    }
    prev = entry;
  }
  return out;
}

void main() {
  const size = 64;

  print('\n--- LZW round trip ---');
  // A varied index stream: gradients force dictionary growth and code-width
  // changes, which is where a hand-rolled LZW usually breaks.
  final pseudo = Uint8List(40000);
  var seed = 12345;
  for (var i = 0; i < pseudo.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    pseudo[i] = (seed >> 16) & 0xFF;
  }
  final compressed = GifEncoder.lzwCompressForTest(pseudo, 8);
  final restored = lzwDecode(compressed, 8);
  check('lzw round trip length', restored.length == pseudo.length);
  var mismatch = 0;
  for (var i = 0; i < math.min(restored.length, pseudo.length); i++) {
    if (restored[i] != pseudo[i]) mismatch++;
  }
  check('lzw round trip bytes ($mismatch mismatches)', mismatch == 0);

  // Uniform and single-value streams are the degenerate cases.
  final flat = Uint8List(5000);
  final flatOut = lzwDecode(GifEncoder.lzwCompressForTest(flat, 8), 8);
  check(
    'lzw flat stream',
    flatOut.length == 5000 && flatOut.every((v) => v == 0),
  );

  final single = Uint8List.fromList(List<int>.filled(3000, 200));
  final singleOut = lzwDecode(GifEncoder.lzwCompressForTest(single, 8), 8);
  check(
    'lzw single value stream',
    singleOut.length == 3000 && singleOut.every((v) => v == 200),
  );

  final tiny = Uint8List.fromList(<int>[1, 2, 3]);
  check(
    'lzw tiny stream',
    lzwDecode(GifEncoder.lzwCompressForTest(tiny, 8), 8).join(',') == '1,2,3',
  );

  print('\n--- palette quantisation ---');
  final enc = GifEncoder(loop: 0);
  enc.addFrame(makeFrame(size, 32, 32, 18), size, size);
  enc.addFrame(makeFrame(size, 40, 32, 18), size, size);
  enc.addFrame(makeFrame(size, 46, 32, 18), size, size);
  final gif = enc.finish();

  print('\n--- file structure ---');
  check(
    'starts with GIF89a',
    String.fromCharCodes(gif.sublist(0, 6)) == 'GIF89a',
  );
  check('ends with trailer 0x3B', gif.last == 0x3B);
  // GIF stores these two-byte fields LOW BYTE FIRST.
  check('logical width is 64 (little endian)', gif[6] == 64 && gif[7] == 0);
  check('logical height is 64 (little endian)', gif[8] == 64 && gif[9] == 0);
  check('global colour table flagged', (gif[10] & 0x80) != 0);
  check('colour table is 256 entries', (gif[10] & 0x07) == 7);
  check('file is reasonably sized', gif.length > 200 && gif.length < 400000);

  // The Netscape loop extension must be present.
  var loopFound = false;
  for (var i = 0; i < gif.length - 12; i++) {
    if (gif[i] == 0x21 && gif[i + 1] == 0xFF && gif[i + 2] == 0x0B) {
      final tag = String.fromCharCodes(gif.sublist(i + 3, i + 14));
      if (tag == 'NETSCAPE2.0') {
        loopFound = true;
        break;
      }
    }
  }
  check('Netscape looping extension present', loopFound);

  print('\n--- error handling ---');
  var sizeMismatchCaught = false;
  try {
    final e2 = GifEncoder();
    e2.addFrame(makeFrame(32, 16, 16, 8), 32, 32);
    e2.addFrame(makeFrame(48, 24, 24, 8), 48, 48);
    e2.finish();
  } on ArgumentError {
    sizeMismatchCaught = true;
  }
  check('mismatched frame sizes rejected', sizeMismatchCaught);

  var emptyCaught = false;
  try {
    GifEncoder().finish();
  } on StateError {
    emptyCaught = true;
  }
  check('empty export rejected', emptyCaught);

  // Write the file out for the PIL cross-check.
  final out = File('${Directory.current.path}/gif_smoke_output.gif');
  out.writeAsBytesSync(gif);
  print('\n  wrote ${out.path} (${gif.length} bytes) for PIL cross-check');

  print('\n=====================================');
  print('checks: $_checks   failures: $_failures');
  print('=====================================');
  if (_failures > 0) throw StateError('$_failures check(s) failed');
}
