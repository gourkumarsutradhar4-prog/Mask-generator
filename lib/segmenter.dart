// segmenter.dart
// নিজস্ব অ্যালগরিদম: কোনো pre-trained / ready-made মডেল নেই।
// রঙের হিস্টোগ্রাম (subject বনাম background) + কিনারা-সচেতন smoothing (ICM)।
// সব ভারী কাজ Isolate-এ চলে, তাই UI আটকায় না।

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int kSaveLong = 2048; // সেভ করা ছবির সর্বোচ্চ লম্বা পাশ
const int kDispLong = 1024; // স্ক্রিনে দেখানোর ছবি
const int kWorkLong = 384; // অ্যালগরিদম চলে এই সাইজে

const int _nbins = 4096; // 16 x 16 x 16 রঙের বাক্স

// ---------------------------------------------------------------------------
// ছবি তৈরি (লোড + EXIF ঘোরানো + ছোট করা)
// ---------------------------------------------------------------------------

class Prepared {
  Prepared(this.sw, this.sh, this.rgb, this.dw, this.dh, this.dispRgba, this.ww,
      this.wh, this.workRgba);
  final int sw, sh; // সেভ করার সাইজ
  final Uint8List rgb; // sw*sh*3
  final int dw, dh; // ডিসপ্লে সাইজ
  final Uint8List dispRgba;
  final int ww, wh; // ওয়ার্কিং সাইজ
  final Uint8List workRgba;
}

Future<Prepared> prepareInBackground(String path) =>
    Isolate.run(() => prepareImage(path));

Prepared prepareImage(String path) {
  final bytes = File(path).readAsBytesSync();
  img.Image? im = img.decodeImage(bytes);
  if (im == null) {
    throw Exception('ছবি পড়া যায়নি');
  }
  im = img.bakeOrientation(im); // ফোনের ছবি সোজা করা
  final big = _fitLong(im, kSaveLong);
  final disp = _fitLong(big, kDispLong);
  final work = _fitLong(disp, kWorkLong);
  return Prepared(
    big.width,
    big.height,
    _toRgb(big),
    disp.width,
    disp.height,
    _rgbToRgba(_toRgb(disp)),
    work.width,
    work.height,
    _rgbToRgba(_toRgb(work)),
  );
}

img.Image _fitLong(img.Image im, int maxLong) {
  final long = math.max(im.width, im.height);
  if (long <= maxLong) return im;
  final s = maxLong / long;
  return img.copyResize(
    im,
    width: math.max(1, (im.width * s).round()),
    height: math.max(1, (im.height * s).round()),
    interpolation: img.Interpolation.average,
  );
}

Uint8List _toRgb(img.Image src) {
  var im = src;
  if (im.hasPalette) im = im.convert(numChannels: 3);
  final out = Uint8List(im.width * im.height * 3);
  final gray = im.numChannels <= 2;
  var o = 0;
  for (final p in im) {
    final r = _b(p.rNormalized);
    if (gray) {
      out[o++] = r;
      out[o++] = r;
      out[o++] = r;
    } else {
      out[o++] = r;
      out[o++] = _b(p.gNormalized);
      out[o++] = _b(p.bNormalized);
    }
  }
  return out;
}

int _b(num v) {
  final x = (v * 255).round();
  if (x < 0) return 0;
  if (x > 255) return 255;
  return x;
}

Uint8List _rgbToRgba(Uint8List rgb) {
  final n = rgb.length ~/ 3;
  final out = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    out[i * 4] = rgb[i * 3];
    out[i * 4 + 1] = rgb[i * 3 + 1];
    out[i * 4 + 2] = rgb[i * 3 + 2];
    out[i * 4 + 3] = 255;
  }
  return out;
}

// ---------------------------------------------------------------------------
// সেগমেন্টেশন
// ---------------------------------------------------------------------------

class SegInput {
  SegInput(this.w, this.h, this.rgba, this.seeds, this.box);
  final int w, h;
  final Uint8List rgba; // w*h*4
  final Uint8List seeds; // 0 = কিছু না, 1 = সবুজ (subject), 2 = লাল (background)
  final List<int>? box; // [x0, y0, x1, y1] বা null
}

class SegResult {
  SegResult(this.w, this.h, this.mask, this.table);
  final int w, h;
  final Uint8List mask; // 0 / 1
  final Float32List table; // রঙের log-ratio (হাই-রেজোলিউশন কিনারা ঠিক করতে লাগে)
}

Future<SegResult> segmentInBackground(SegInput input) =>
    Isolate.run(() => runSegmentation(input));

Float64List _smoothHist(Float64List h) {
  var src = h;
  for (var axis = 0; axis < 3; axis++) {
    final stride = axis == 0 ? 256 : (axis == 1 ? 16 : 1);
    final dst = Float64List(_nbins);
    for (var i = 0; i < _nbins; i++) {
      final coord = (i ~/ stride) % 16;
      final c = src[i];
      final lo = coord > 0 ? src[i - stride] : c;
      final hi = coord < 15 ? src[i + stride] : c;
      dst[i] = (lo + 2 * c + hi) / 4.0;
    }
    src = dst;
  }
  return src;
}

Float64List _makeHist(Int32List bn, Float64List w) {
  var h = Float64List(_nbins);
  for (var i = 0; i < bn.length; i++) {
    final wi = w[i];
    if (wi != 0) h[bn[i]] += wi;
  }
  h = _smoothHist(h);
  var s = 0.0;
  for (var b = 0; b < _nbins; b++) {
    s += h[b];
  }
  final denom = s + 0.5 * _nbins;
  for (var b = 0; b < _nbins; b++) {
    h[b] = (h[b] + 0.5) / denom;
  }
  return h;
}

class _Comps {
  _Comps(this.id, this.sizes, this.border);
  final Int32List id; // 0 = এই লেবেল না, 1.. = কম্পোনেন্ট নম্বর
  final List<int> sizes; // index 0 অব্যবহৃত
  final List<bool> border;
}

_Comps _components(Uint8List m, int w, int h, int target) {
  final n = w * h;
  final id = Int32List(n);
  final queue = Int32List(n);
  final sizes = <int>[0];
  final border = <bool>[false];
  var count = 0;
  for (var s = 0; s < n; s++) {
    if (m[s] != target || id[s] != 0) continue;
    count++;
    var head = 0, tail = 0, size = 0;
    var touches = false;
    queue[tail++] = s;
    id[s] = count;
    while (head < tail) {
      final i = queue[head++];
      size++;
      final x = i % w, y = i ~/ w;
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1) touches = true;
      if (x > 0 && m[i - 1] == target && id[i - 1] == 0) {
        id[i - 1] = count;
        queue[tail++] = i - 1;
      }
      if (x < w - 1 && m[i + 1] == target && id[i + 1] == 0) {
        id[i + 1] = count;
        queue[tail++] = i + 1;
      }
      if (y > 0 && m[i - w] == target && id[i - w] == 0) {
        id[i - w] = count;
        queue[tail++] = i - w;
      }
      if (y < h - 1 && m[i + w] == target && id[i + w] == 0) {
        id[i + w] = count;
        queue[tail++] = i + w;
      }
    }
    sizes.add(size);
    border.add(touches);
  }
  return _Comps(id, sizes, border);
}

SegResult runSegmentation(SegInput inp) {
  const int iters = 4;
  const int sweeps = 6;
  const double lam = 1.0;
  const double aMix = 0.7;

  final w = inp.w, h = inp.h, n = w * h;
  final rgba = inp.rgba;
  final seeds = inp.seeds;

  final bn = Int32List(n);
  for (var i = 0; i < n; i++) {
    bn[i] = ((rgba[i * 4] >> 4) << 8) |
        ((rgba[i * 4 + 1] >> 4) << 4) |
        (rgba[i * 4 + 2] >> 4);
  }

  final fixedFg = Uint8List(n);
  final fixedBg = Uint8List(n);
  final redSeed = Uint8List(n);
  final inBox = Uint8List(n);
  var hasSeedFg = false;
  for (var i = 0; i < n; i++) {
    if (seeds[i] == 1) {
      fixedFg[i] = 1;
      hasSeedFg = true;
    } else if (seeds[i] == 2) {
      fixedBg[i] = 1;
      redSeed[i] = 1;
    }
  }

  final F = Uint8List(n); // subject নমুনা
  final B = Uint8List(n); // background নমুনা
  final box = inp.box;
  if (box != null) {
    final x0 = box[0], y0 = box[1], x1 = box[2], y1 = box[3];
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        inBox[y * w + x] = 1;
      }
    }
    for (var i = 0; i < n; i++) {
      if (inBox[i] == 0 && fixedFg[i] == 0) fixedBg[i] = 1;
    }
    final bw = x1 - x0, bh = y1 - y0;
    for (var y = y0 + bh ~/ 4; y < y1 - bh ~/ 4; y++) {
      for (var x = x0 + bw ~/ 4; x < x1 - bw ~/ 4; x++) {
        F[y * w + x] = 1;
      }
    }
    for (var i = 0; i < n; i++) {
      if (fixedFg[i] == 1) F[i] = 1;
      if (fixedBg[i] == 1) B[i] = 1;
    }
  } else {
    for (var i = 0; i < n; i++) {
      inBox[i] = 1;
    }
    final m = math.max(2, (0.04 * math.min(w, h)).round());
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (x < m || y < m || x >= w - m || y >= h - m) B[i] = 1;
        if (fixedBg[i] == 1) B[i] = 1;
        if (fixedFg[i] == 1) F[i] = 1;
      }
    }
  }

  // কিনারার ওজন: রঙ আলাদা হলে কম, কাছাকাছি হলে বেশি
  final wh = Float32List(n);
  final wv = Float32List(n);
  double sum = 0;
  int cnt = 0;
  double dsq(int a, int b) {
    final dr = rgba[a * 4] - rgba[b * 4];
    final dg = rgba[a * 4 + 1] - rgba[b * 4 + 1];
    final db = rgba[a * 4 + 2] - rgba[b * 4 + 2];
    return (dr * dr + dg * dg + db * db).toDouble();
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (x < w - 1) {
        final d = dsq(i, i + 1);
        wh[i] = d;
        sum += d;
        cnt++;
      }
      if (y < h - 1) {
        final d = dsq(i, i + w);
        wv[i] = d;
        sum += d;
        cnt++;
      }
    }
  }
  final beta = 1.0 / (2.0 * ((cnt > 0 ? sum / cnt : 1.0) + 1e-6));
  for (var i = 0; i < n; i++) {
    wh[i] = math.exp(-beta * wh[i]);
    wv[i] = math.exp(-beta * wv[i]);
  }

  final lab = Uint8List(n);
  final U = Float32List(n);
  final table = Float32List(_nbins);
  final wf = Float64List(n);
  final wb = Float64List(n);
  const u = 1.0 / _nbins;

  for (var it = 0; it < iters; it++) {
    for (var i = 0; i < n; i++) {
      wf[i] = F[i] + (fixedFg[i] == 1 ? 19.0 : 0.0);
      wb[i] = B[i] + (redSeed[i] == 1 ? 19.0 : 0.0);
    }
    final pf = _makeHist(bn, wf);
    final pb = _makeHist(bn, wb);
    for (var b = 0; b < _nbins; b++) {
      var v = math.log(aMix * pf[b] + (1 - aMix) * u) - math.log(pb[b]);
      if (v > 6) v = 6;
      if (v < -6) v = -6;
      table[b] = v;
    }
    for (var i = 0; i < n; i++) {
      U[i] = table[bn[i]];
      lab[i] = U[i] > 0 ? 1 : 0;
      if (fixedFg[i] == 1) lab[i] = 1;
      if (fixedBg[i] == 1) lab[i] = 0;
    }
    // কিনারা-সচেতন smoothing (শতরঞ্চের ছকে আপডেট)
    for (var sw = 0; sw < sweeps; sw++) {
      for (var par = 0; par < 2; par++) {
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            if (((x + y) & 1) != par) continue;
            final i = y * w + x;
            if (fixedFg[i] == 1 || fixedBg[i] == 1) continue;
            double acc = 0;
            if (x > 0) acc += wh[i - 1] * (lab[i - 1] == 1 ? 1 : -1);
            if (x < w - 1) acc += wh[i] * (lab[i + 1] == 1 ? 1 : -1);
            if (y > 0) acc += wv[i - w] * (lab[i - w] == 1 ? 1 : -1);
            if (y < h - 1) acc += wv[i] * (lab[i + w] == 1 ? 1 : -1);
            lab[i] = (U[i] + lam * acc) > 0 ? 1 : 0;
          }
        }
      }
    }
    for (var i = 0; i < n; i++) {
      F[i] = (lab[i] == 1 && inBox[i] == 1) ? 1 : 0;
      B[i] = (lab[i] == 0 || inBox[i] == 0) ? 1 : 0;
    }
  }

  // শুধু সবুজ দাগ ছোঁয়া (বা সবচেয়ে বড়) অংশ রাখা
  final c = _components(lab, w, h, 1);
  final keep = Uint8List(c.sizes.length);
  var any = false;
  if (hasSeedFg) {
    for (var i = 0; i < n; i++) {
      if (fixedFg[i] == 1 && c.id[i] > 0) {
        keep[c.id[i]] = 1;
        any = true;
      }
    }
  }
  if (!any && c.sizes.length > 1) {
    var best = 1;
    for (var k = 2; k < c.sizes.length; k++) {
      if (c.sizes[k] > c.sizes[best]) best = k;
    }
    keep[best] = 1;
  }
  for (var i = 0; i < n; i++) {
    lab[i] = (c.id[i] > 0 && keep[c.id[i]] == 1) ? 1 : 0;
  }

  // ছোট ফুটো ভরাট (লাল দাগ থাকলে ভরাট হবে না)
  final c2 = _components(lab, w, h, 0);
  final hasRed = Uint8List(c2.sizes.length);
  for (var i = 0; i < n; i++) {
    if (redSeed[i] == 1 && c2.id[i] > 0) hasRed[c2.id[i]] = 1;
  }
  final holeLimit = 0.003 * n;
  for (var i = 0; i < n; i++) {
    final k = c2.id[i];
    if (k > 0 && !c2.border[k] && hasRed[k] == 0 && c2.sizes[k] < holeLimit) {
      lab[i] = 1;
    }
  }

  return SegResult(w, h, lab, table);
}

// ---------------------------------------------------------------------------
// সেভের সময়: ছোট মাস্ক -> পুরো সাইজের মাস্ক (কিনারা রঙ দেখে ঠিক করা) + JPG/PNG
// ---------------------------------------------------------------------------

class ExportInput {
  ExportInput(
    this.sw,
    this.sh,
    this.rgb,
    this.mw,
    this.mh,
    this.mask,
    this.table, {
    required this.edits,
    required this.workRgba,
    this.marks,
    required this.subject,
  });
  final int sw, sh;
  final Uint8List rgb;
  final int mw, mh;
  final Uint8List mask; // অ্যালগরিদমের মাস্ক (ওয়ার্কিং সাইজ, 0/1)
  final Float32List table;
  final Float32List edits; // সাদা/কালো ব্রাশের দাগ (applyEdits-এর ফরম্যাট)
  final Uint8List workRgba; // AI ট্রেনিং ডেটার ছোট ছবি
  final Uint8List? marks; // সবুজ দাগ (ওয়ার্কিং সাইজ, 0/1) – থাকলে AI ডেটা সেভ হবে
  final Uint8List subject; // ব্রাশসহ চূড়ান্ত মাস্ক (ওয়ার্কিং সাইজ, 0/1)
}

class ExportResult {
  ExportResult(this.jpg, this.png, {this.markJpg, this.markPng, this.subjectPng});
  final Uint8List jpg;
  final Uint8List png;
  final Uint8List? markJpg;
  final Uint8List? markPng;
  final Uint8List? subjectPng;
}

// সাদা/কালো ব্রাশের দাগ বসানো।
// rec ফরম্যাট (পরপর): [রঙ(1=সাদা,2=কালো), ব্যাসার্ধ, বিন্দুর সংখ্যা n, x0,y0, x1,y1, ...]
// স্থানাঙ্ক ওয়ার্কিং-গ্রিডে; scale দিয়ে buf-এর সাইজে আনা হয়।
void applyEdits(Uint8List buf, int bw, int bh, double scale, Float32List rec, int whiteVal) {
  var i = 0;
  while (i + 2 < rec.length) {
    final v = rec[i].toInt();
    final r = rec[i + 1] * scale;
    final n = rec[i + 2].toInt();
    i += 3;
    final val = v == 1 ? whiteVal : 0;
    double? px;
    double? py;
    for (var k = 0; k < n; k++) {
      final x = rec[i + 2 * k] * scale;
      final y = rec[i + 2 * k + 1] * scale;
      if (px != null && py != null) {
        final dx = x - px, dy = y - py;
        final d = math.sqrt(dx * dx + dy * dy);
        final steps = (d / math.max(1.0, r * 0.5)).ceil();
        for (var s = 1; s < steps; s++) {
          final t = s / steps;
          _stampFill(buf, bw, bh, px + dx * t, py + dy * t, r, val);
        }
      }
      _stampFill(buf, bw, bh, x, y, r, val);
      px = x;
      py = y;
    }
    i += 2 * n;
  }
}

void _stampFill(Uint8List buf, int w, int h, double cx, double cy, double r, int val) {
  final x0 = math.max(0, (cx - r).floor());
  final x1 = math.min(w - 1, (cx + r).ceil());
  final y0 = math.max(0, (cy - r).floor());
  final y1 = math.min(h - 1, (cy + r).ceil());
  final r2 = r * r;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r2) buf[y * w + x] = val;
    }
  }
}

Future<ExportResult> exportInBackground(ExportInput input) =>
    Isolate.run(() => runExport(input));

Float32List _boxBlur(Float32List src, int w, int h, int r) {
  final tmp = Float32List(w * h);
  final dst = Float32List(w * h);
  final k = (2 * r + 1).toDouble();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      double s = 0;
      for (var d = -r; d <= r; d++) {
        final xx = (x + d).clamp(0, w - 1).toInt();
        s += src[y * w + xx];
      }
      tmp[y * w + x] = s / k;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      double s = 0;
      for (var d = -r; d <= r; d++) {
        final yy = (y + d).clamp(0, h - 1).toInt();
        s += tmp[yy * w + x];
      }
      dst[y * w + x] = s / k;
    }
  }
  return dst;
}

ExportResult runExport(ExportInput e) {
  final sw = e.sw, sh = e.sh, mw = e.mw, mh = e.mh;
  var soft = Float32List(mw * mh);
  for (var i = 0; i < soft.length; i++) {
    soft[i] = e.mask[i].toDouble();
  }
  soft = _boxBlur(soft, mw, mh, 2);
  soft = _boxBlur(soft, mw, mh, 2);

  final x0 = Int32List(sw), x1 = Int32List(sw);
  final fx = Float32List(sw);
  for (var x = 0; x < sw; x++) {
    final f = (x + 0.5) * mw / sw - 0.5;
    final i0 = f.floor();
    fx[x] = f - i0;
    x0[x] = i0.clamp(0, mw - 1).toInt();
    x1[x] = (i0 + 1).clamp(0, mw - 1).toInt();
  }

  final out = Uint8List(sw * sh);
  final table = e.table;
  final rgb = e.rgb;
  for (var y = 0; y < sh; y++) {
    final f = (y + 0.5) * mh / sh - 0.5;
    final j0 = f.floor();
    final ty = f - j0;
    final r0 = j0.clamp(0, mh - 1).toInt() * mw;
    final r1 = (j0 + 1).clamp(0, mh - 1).toInt() * mw;
    for (var x = 0; x < sw; x++) {
      final a = soft[r0 + x0[x]];
      final b = soft[r0 + x1[x]];
      final c = soft[r1 + x0[x]];
      final d = soft[r1 + x1[x]];
      final t = fx[x];
      final s = (a * (1 - t) + b * t) * (1 - ty) + (c * (1 - t) + d * t) * ty;
      int v;
      if (s <= 0.03) {
        v = 0;
      } else if (s >= 0.97) {
        v = 255;
      } else {
        // কিনারার সরু বেল্ট: পিক্সেলের নিজের রঙ দেখে সিদ্ধান্ত
        final k = (y * sw + x) * 3;
        final bin = ((rgb[k] >> 4) << 8) | ((rgb[k + 1] >> 4) << 4) | (rgb[k + 2] >> 4);
        var lr = table[bin];
        if (lr > 4) lr = 4;
        if (lr < -4) lr = -4;
        v = ((s - 0.5) * 6 + 0.6 * lr) > 0 ? 255 : 0;
      }
      out[y * sw + x] = v;
    }
  }

  // সাদা/কালো ব্রাশের সংশোধন (পুরো সাইজে, তাই কিনারা নিখুঁত থাকে)
  if (e.edits.isNotEmpty) {
    applyEdits(out, sw, sh, sw / mw, e.edits, 255);
  }

  final photo = img.Image.fromBytes(
    width: sw,
    height: sh,
    bytes: rgb.buffer,
    numChannels: 3,
  );
  final jpg = Uint8List.fromList(img.encodeJpg(photo, quality: 92));
  final png = _grayPng(out, sw, sh);

  // AI ট্রেনিং ডেটা: ছোট ছবি + সবুজ দাগ + (মাপার জন্য) subject মাস্ক
  Uint8List? markJpg, markPng, subjectPng;
  final marks = e.marks;
  if (marks != null) {
    final n = mw * mh;
    final wrgb = Uint8List(n * 3);
    for (var i = 0; i < n; i++) {
      wrgb[i * 3] = e.workRgba[i * 4];
      wrgb[i * 3 + 1] = e.workRgba[i * 4 + 1];
      wrgb[i * 3 + 2] = e.workRgba[i * 4 + 2];
    }
    final wimg = img.Image.fromBytes(width: mw, height: mh, bytes: wrgb.buffer, numChannels: 3);
    markJpg = Uint8List.fromList(img.encodeJpg(wimg, quality: 92));
    final m255 = Uint8List(n);
    final s255 = Uint8List(n);
    for (var i = 0; i < n; i++) {
      m255[i] = marks[i] == 1 ? 255 : 0;
      s255[i] = e.subject[i] == 1 ? 255 : 0;
    }
    markPng = _grayPng(m255, mw, mh);
    subjectPng = _grayPng(s255, mw, mh);
  }
  return ExportResult(jpg, png, markJpg: markJpg, markPng: markPng, subjectPng: subjectPng);
}

Uint8List _grayPng(Uint8List px, int w, int h) {
  final g = img.Image.fromBytes(width: w, height: h, bytes: px.buffer, numChannels: 1);
  return Uint8List.fromList(img.encodePng(g));
}
