// marker.dart
// "সবুজ দাগ বসানো AI": ছবি দেখে subject-এর ভেতরে কোথায় সবুজ দাগ পড়বে তা অনুমান করে।
// মডেল PC-তে ট্রেন হয় (tools/train_marker.py), এখানে শুধু চালানো হয় (ফোনে ট্রেনিং নেই)।
// কোনো বাইরের লাইব্রেরি লাগে না: ওজন ফাইল (marker_model.bin) পড়ে সরাসরি Dart-এ চলে।
//
// ফাইলের গঠন (little-endian):
//   "MKM1" | int32 size | int32 inCh(=3) | int32 L | int32 filters[L] | int32 bottleneck
//   তারপর float32: প্রতিটা ব্লকের  w1[3][3][cin][cout], b1, w2[3][3][f][f], b2
//   ব্লকের ক্রম: এনকোডার 0..L-1, bottleneck, ডিকোডার L-1..0; শেষে 1x1 conv w[f0], b
//   (BatchNorm আগেই conv-এর ভেতরে মিশিয়ে দেওয়া)

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

class MarkerNet {
  MarkerNet._(this.size, this.inCh, this.filters, this.bott, this.data);

  final int size;
  final int inCh;
  final List<int> filters;
  final int bott;
  final Float32List data;

  static int _blockFloats(int cin, int f) => 9 * cin * f + f + 9 * f * f + f;

  static MarkerNet parse(Uint8List bytes) {
    if (bytes.length < 24 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'MKM1') {
      throw const FormatException('AI ফাইল ঠিক নেই (MKM1 পাওয়া যায়নি)');
    }
    final bd = ByteData.sublistView(bytes);
    var o = 4;
    int rd() {
      final v = bd.getInt32(o, Endian.little);
      o += 4;
      return v;
    }

    final size = rd();
    final inCh = rd();
    final levels = rd();
    if (levels < 1 || levels > 8 || size < 16 || size % (1 << levels) != 0 || inCh != 3) {
      throw const FormatException('AI ফাইলের হেডার ঠিক নেই');
    }
    final filters = <int>[for (var i = 0; i < levels; i++) rd()];
    final bott = rd();

    // প্রত্যাশিত float সংখ্যা মিলিয়ে দেখা
    var expect = 0;
    var c = inCh;
    for (final f in filters) {
      expect += _blockFloats(c, f);
      c = f;
    }
    expect += _blockFloats(c, bott);
    c = bott;
    for (var i = levels - 1; i >= 0; i--) {
      expect += _blockFloats(c + filters[i], filters[i]);
      c = filters[i];
    }
    expect += filters[0] + 1;
    final n = (bytes.length - o) ~/ 4;
    if (n != expect) {
      throw FormatException('AI ফাইলের সাইজ মেলে না ($n, দরকার $expect)');
    }
    final data = Float32List(n);
    for (var i = 0; i < n; i++) {
      data[i] = bd.getFloat32(o + i * 4, Endian.little);
    }
    return MarkerNet._(size, inCh, filters, bott, data);
  }

  Float32List _conv3(Float32List x, int h, int w, int cin, int cout, int wOff, int bOff) {
    final out = Float32List(h * w * cout);
    final acc = Float32List(cout);
    final d = data;
    for (var y = 0; y < h; y++) {
      for (var xx = 0; xx < w; xx++) {
        for (var co = 0; co < cout; co++) {
          acc[co] = d[bOff + co];
        }
        for (var ky = 0; ky < 3; ky++) {
          final yy = y + ky - 1;
          if (yy < 0 || yy >= h) continue;
          for (var kx = 0; kx < 3; kx++) {
            final x2 = xx + kx - 1;
            if (x2 < 0 || x2 >= w) continue;
            final base = (yy * w + x2) * cin;
            final wb = wOff + (ky * 3 + kx) * cin * cout;
            for (var ci = 0; ci < cin; ci++) {
              final v = x[base + ci];
              if (v == 0) continue;
              final wo = wb + ci * cout;
              for (var co = 0; co < cout; co++) {
                acc[co] += v * d[wo + co];
              }
            }
          }
        }
        final ob = (y * w + xx) * cout;
        for (var co = 0; co < cout; co++) {
          final v = acc[co];
          out[ob + co] = v > 0 ? v : 0;
        }
      }
    }
    return out;
  }

  Float32List _pool(Float32List x, int h, int w, int c) {
    final oh = h ~/ 2, ow = w ~/ 2;
    final out = Float32List(oh * ow * c);
    for (var y = 0; y < oh; y++) {
      for (var xx = 0; xx < ow; xx++) {
        for (var ch = 0; ch < c; ch++) {
          final a = x[((2 * y) * w + 2 * xx) * c + ch];
          final b = x[((2 * y) * w + 2 * xx + 1) * c + ch];
          final cc = x[((2 * y + 1) * w + 2 * xx) * c + ch];
          final dd = x[((2 * y + 1) * w + 2 * xx + 1) * c + ch];
          out[(y * ow + xx) * c + ch] = math.max(math.max(a, b), math.max(cc, dd));
        }
      }
    }
    return out;
  }

  // nearest-neighbour ২ গুণ বড় করা + skip-এর সাথে জোড়া ([up, skip] ক্রমে)
  Float32List _upConcat(Float32List x, int h, int w, int c, Float32List skip, int cs) {
    final oh = h * 2, ow = w * 2;
    final cc = c + cs;
    final out = Float32List(oh * ow * cc);
    for (var y = 0; y < oh; y++) {
      for (var xx = 0; xx < ow; xx++) {
        final o = (y * ow + xx) * cc;
        final s = ((y ~/ 2) * w + (xx ~/ 2)) * c;
        for (var ch = 0; ch < c; ch++) {
          out[o + ch] = x[s + ch];
        }
        final k = (y * ow + xx) * cs;
        for (var ch = 0; ch < cs; ch++) {
          out[o + c + ch] = skip[k + ch];
        }
      }
    }
    return out;
  }

  /// input: size*size*3 (0..1)  ->  size*size সম্ভাবনা (0..1)
  Float32List forward(Float32List input) {
    var pos = 0;
    Float32List block(Float32List x, int h, int w, int cin, int f) {
      final a = _conv3(x, h, w, cin, f, pos, pos + 9 * cin * f);
      pos += 9 * cin * f + f;
      final b = _conv3(a, h, w, f, f, pos, pos + 9 * f * f);
      pos += 9 * f * f + f;
      return b;
    }

    final skips = <Float32List>[];
    var x = input;
    var h = size, w = size, c = inCh;
    for (final f in filters) {
      x = block(x, h, w, c, f);
      skips.add(x);
      x = _pool(x, h, w, f);
      h ~/= 2;
      w ~/= 2;
      c = f;
    }
    x = block(x, h, w, c, bott);
    c = bott;
    for (var i = filters.length - 1; i >= 0; i--) {
      final f = filters[i];
      x = _upConcat(x, h, w, c, skips[i], f);
      h *= 2;
      w *= 2;
      x = block(x, h, w, c + f, f);
      c = f;
    }
    final out = Float32List(h * w);
    final f0 = filters[0];
    final bias = data[pos + f0];
    for (var p = 0; p < h * w; p++) {
      var s = bias;
      for (var ci = 0; ci < f0; ci++) {
        s += x[p * f0 + ci] * data[pos + ci];
      }
      out[p] = 1.0 / (1.0 + math.exp(-s));
    }
    return out;
  }
}

class MarkerInput {
  MarkerInput(this.model, this.w, this.h, this.rgba);
  final Uint8List model; // marker_model.bin এর বাইট
  final int w, h;
  final Uint8List rgba; // w*h*4 (ওয়ার্কিং সাইজের ছবি)
}

/// ছবিতে সবুজ দাগের জায়গা (w*h, 1 = সবুজ)। AI নিশ্চিত না হলে null।
Future<Uint8List?> markerInBackground(MarkerInput input) =>
    Isolate.run(() => runMarker(input));

Uint8List? runMarker(MarkerInput inp) {
  final net = MarkerNet.parse(inp.model);
  final s = net.size;
  final w = inp.w, h = inp.h;
  final rgba = inp.rgba;

  // ছবি s x s করা (box-average, ট্রেনিংয়ের Image.BOX-এর মতো)
  final x = Float32List(s * s * 3);
  for (var oy = 0; oy < s; oy++) {
    final y0 = (oy * h) ~/ s;
    final y1 = math.min(h, math.max(y0 + 1, ((oy + 1) * h + s - 1) ~/ s));
    for (var ox = 0; ox < s; ox++) {
      final x0 = (ox * w) ~/ s;
      final x1 = math.min(w, math.max(x0 + 1, ((ox + 1) * w + s - 1) ~/ s));
      double r = 0, g = 0, b = 0;
      var cnt = 0;
      for (var yy = y0; yy < y1; yy++) {
        for (var xx = x0; xx < x1; xx++) {
          final i = (yy * w + xx) * 4;
          r += rgba[i];
          g += rgba[i + 1];
          b += rgba[i + 2];
          cnt++;
        }
      }
      final o = (oy * s + ox) * 3;
      x[o] = r / (cnt * 255);
      x[o + 1] = g / (cnt * 255);
      x[o + 2] = b / (cnt * 255);
    }
  }

  final p = net.forward(x);
  var pmax = 0.0;
  for (final v in p) {
    if (v > pmax) pmax = v;
  }
  if (pmax < 0.25) return null; // AI নিশ্চিত না

  final thr = math.max(0.5 * pmax, 0.2);
  // bilinear করে ওয়ার্কিং সাইজে বড় করা, তারপর threshold
  final out = Uint8List(w * h);
  var any = false;
  for (var y = 0; y < h; y++) {
    final fy = (y + 0.5) * s / h - 0.5;
    final y0 = fy.floor();
    final ty = fy - y0;
    final ya = y0.clamp(0, s - 1).toInt();
    final yb = (y0 + 1).clamp(0, s - 1).toInt();
    for (var xx = 0; xx < w; xx++) {
      final fx = (xx + 0.5) * s / w - 0.5;
      final x0 = fx.floor();
      final tx = fx - x0;
      final xa = x0.clamp(0, s - 1).toInt();
      final xb = (x0 + 1).clamp(0, s - 1).toInt();
      final v = (p[ya * s + xa] * (1 - tx) + p[ya * s + xb] * tx) * (1 - ty) +
          (p[yb * s + xa] * (1 - tx) + p[yb * s + xb] * tx) * ty;
      if (v >= thr) {
        out[y * w + xx] = 1;
        any = true;
      }
    }
  }
  return any ? out : null;
}
