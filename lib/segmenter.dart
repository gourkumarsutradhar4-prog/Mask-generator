import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class Segmenter {
  static Uint8List run({
    required img.Image image,
    required Uint8List seeds,
    double edgeWeight = 6,
    double colorWeight = 1,
  }) {
    final w = image.width;
    final h = image.height;
    final n = w * h;h
    final red = Float32List(n);
    final green = Float32List(n);
    final blue = Float32List(n);
    final gray = Float32List(n);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        final i = y * w + x;
        red[i] = p.r.toDouble();
        green[i] = p.g.toDouble();
        blue[i] = p.b.toDouble();
        gray[i] = 0.299 * red[i] + 0.587 * green[i] + 0.114 * blue[i];
      }
    }

    final edge = Float32List(n);
    var sum = 0.0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final tl = gray[i - w - 1], tc = gray[i - w], tr = gray[i - w + 1];
        final ml = gray[i - 1], mr = gray[i + 1];
        final bl = gray[i + w - 1], bc = gray[i + w], br = gray[i + w + 1];
        final gx = (tr + 2 * mr + br) - (tl + 2 * ml + bl);
        final gy = (bl + 2 * bc + br) - (tl + 2 * tc + tr);
        final m = math.sqrt(gx * gx + gy * gy);
        edge[i] = m;
        sum += m;
      }
    }
    final norm = math.max(sum / n * 4, 1e-6);
    for (var i = 0; i < n; i++) {
      edge[i] = math.min(1.0, edge[i] / norm);
    }

    // ৩) দুই পক্ষের প্রতিযোগিতা: সবচেয়ে কম খরচে যে আগে পৌঁছায়, পিক্সেল তার
    final dist = Float64List(n)..fillRange(0, n, double.infinity);
    final label = Uint8List(n);
    final heap = _MinHeap();
    for (var i = 0; i < n; i++) {
      if (seeds[i] != 0) {
        dist[i] = 0;
        label[i] = seeds[i];
        heap.push(0, i);
      }
    }

    const dxs = [1, -1, 0, 0];
    const dys = [0, 0, 1, -1];
    while (!heap.isEmpty) {
      final p = heap.pop();
      final d = heap.lastKey;
      if (d > dist[p]) continue;
      final px = p % w;
      final py = p ~/ w;
      for (var k = 0; k < 4; k++) {
        final qx = px + dxs[k];
        final qy = py + dys[k];
        if (qx < 0 || qy < 0 || qx >= w || qy >= h) continue;
        final q = qy * w + qx;
        final dr = red[p] - red[q];
        final dg = green[p] - green[q];
        final db = blue[p] - blue[q];
        final colorDiff = math.sqrt(dr * dr + dg * dg + db * db) / 441.67;
        final cost = 0.02 + colorWeight * colorDiff + edgeWeight * edge[q];
        final nd = d + cost;
        if (nd < dist[q]) {
          dist[q] = nd;
          label[q] = label[p];
          heap.push(nd, q);
        }
      }
    }

    // ৪) সাবজেক্ট = সাদা, বাকি = কালো
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = label[i] == 1 ? 255 : 0;
    }
    return out;
  }
}

/// ছোট একটা মিন-হিপ (সবচেয়ে কম খরচের পিক্সেল আগে বের করার জন্য)
class _MinHeap {
  final List<double> _k = [];
  final List<int> _v = [];
  double lastKey = 0;

  bool get isEmpty => _k.isEmpty;

  void push(double key, int val) {
    _k.add(key);
    _v.add(val);
    var i = _k.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_k[p] <= _k[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  int pop() {
    final topVal = _v[0];
    lastKey = _k[0];
    final lastK = _k.removeLast();
    final lastV = _v.removeLast();
    if (_k.isNotEmpty) {
      _k[0] = lastK;
      _v[0] = lastV;
      var i = 0;
      final len = _k.length;
      while (true) {
        final l = 2 * i + 1;
        final r = l + 1;
        var m = i;
        if (l < len && _k[l] < _k[m]) m = l;
        if (r < len && _k[r] < _k[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return topVal;
  }

  void _swap(int a, int b) {
    final tk = _k[a];
    _k[a] = _k[b];
    _k[b] = tk;
    final tv = _v[a];
    _v[a] = _v[b];
    _v[b] = tv;
  }
} 
