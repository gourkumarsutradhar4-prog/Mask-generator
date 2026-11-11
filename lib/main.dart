// main.dart – Mask Maker
//
// কাজের ধারা:
//   ছবি বাছাই -> AI সবুজ দাগ বসায় (বা আপনি নিজে সবুজ দাগ দেন)
//   -> অ্যাপ দাগ দেখে subject সাদা, ব্যাকগ্রাউন্ড কালো করে
//   -> ভুল থাকলে লাল দাগ / সাদা-কালো ব্রাশ -> Save ➜ Next
// ছবি আর মাস্ক একই নামে DIS5K ফোল্ডারে সেভ হয়।
// আপনি নিজে সবুজ দাগ দিলে সেটা "AI_marks" এ জমে, যা দিয়ে PC-তে AI ট্রেন হয়।

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as pth;
import 'package:share_plus/share_plus.dart';

import 'dataset.dart';
import 'marker.dart';
import 'segmenter.dart';

void main() => runApp(const MaskMakerApp());

class MaskMakerApp extends StatelessWidget {
  const MaskMakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mask Maker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.green,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const MaskScreen(),
    );
  }
}

enum Tool { box, fg, bg, white, black }

class _Stroke {
  _Stroke(this.tool, this.r);
  final Tool tool; // fg / bg / white / black
  final double r; // ওয়ার্কিং-পিক্সেলে ব্যাসার্ধ
  final List<Offset> pts = [];
}

// ওয়ার্কিং গ্রিডে দাগ বসানো
void _stamp(Uint8List seeds, int w, int h, double cx, double cy, double r, int v) {
  final x0 = math.max(0, (cx - r).floor());
  final x1 = math.min(w - 1, (cx + r).ceil());
  final y0 = math.max(0, (cy - r).floor());
  final y1 = math.min(h - 1, (cy + r).ceil());
  final r2 = r * r;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r2) seeds[y * w + x] = v;
    }
  }
}

Future<ui.Image> _toUiImage(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class MaskScreen extends StatefulWidget {
  const MaskScreen({super.key});

  @override
  State<MaskScreen> createState() => _MaskScreenState();
}

class _MaskScreenState extends State<MaskScreen> {
  Dataset? _ds;
  final List<PlatformFile> _queue = [];
  int _idx = 0;

  Prepared? _cur;
  ui.Image? _dispImg;
  ui.Image? _overlay;
  ui.Image? _maskImg;
  ui.Image? _markImg; // AI-র দেওয়া সবুজ দাগ
  SegResult? _seg;

  Uint8List? _modelBytes; // AI (marker_model.bin)
  Uint8List? _aiMark; // AI-র সবুজ দাগ (ওয়ার্কিং সাইজ, 0/1)
  bool _autoAi = true;
  bool _aiBusy = false;

  Rect? _box; // ওয়ার্কিং কোঅর্ডিনেটে
  Offset? _boxStart;
  final List<_Stroke> _strokes = [];
  _Stroke? _active;

  Tool _tool = Tool.fg;
  double _brush = 5;
  bool _maskOnly = false;

  // জুম / সরানো (দুই আঙুলে)। এক আঙুলে শুধু দাগ।
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Size _canvasSize = Size.zero;
  final Map<int, Offset> _ptrs = {};
  bool _gesture = false;
  double _gZoom0 = 1, _gD0 = 1;
  Offset _gPan0 = Offset.zero, _gC0 = Offset.zero;
  bool _loading = false;
  bool _busy = false;
  bool _exporting = false;

  int _segVer = 0;
  int _ovVer = 0;
  int _aiVer = 0;
  Future<void>? _segFuture;
  int _pendingSaves = 0;
  final List<Future<void>> _saves = [];

  // পরের ছবি আগে থেকে তৈরি করে রাখা (অপেক্ষা কমাতে)
  String? _nextPath;
  Future<Prepared>? _nextPrep;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final d = await Dataset.open();
    Uint8List? model;
    try {
      if (await d.modelFile.exists()) {
        final b = await d.modelFile.readAsBytes();
        MarkerNet.parse(b); // ঠিক আছে কিনা যাচাই
        model = b;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _ds = d;
        _modelBytes = model;
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  void _disposeLater(ui.Image? a, [ui.Image? b]) {
    if (a == null && b == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      a?.dispose();
      b?.dispose();
    });
  }

  // ------------------------------------------------------------------ ছবি বাছাই

  Future<void> _pick() async {
    final ds = _ds;
    if (ds == null) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (res == null) return;
    final fresh = res.files
        .where((f) => f.path != null && !ds.isDone(f.name, f.size))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final skipped = res.files.length - fresh.length;
    if (fresh.isEmpty) {
      _toast('সবগুলো ছবি আগেই করা আছে');
      return;
    }
    if (skipped > 0) _toast('$skipped টা আগেই করা, বাদ দিলাম');
    _queue
      ..clear()
      ..addAll(fresh);
    _idx = 0;
    _nextPath = null;
    _nextPrep = null;
    await _open(0);
  }

  Future<Prepared> _prepFor(String path) {
    if (_nextPath == path && _nextPrep != null) {
      final f = _nextPrep!;
      _nextPath = null;
      _nextPrep = null;
      return f;
    }
    return prepareInBackground(path);
  }

  void _resetWork() {
    _zoom = 1;
    _pan = Offset.zero;
    _ptrs.clear();
    _gesture = false;
    _box = null;
    _boxStart = null;
    _active = null;
    _strokes.clear();
    _seg = null;
    _aiMark = null;
    _aiBusy = false;
    _busy = false;
    _disposeLater(_overlay, _maskImg);
    _disposeLater(_markImg);
    _overlay = null;
    _maskImg = null;
    _markImg = null;
  }

  Future<void> _open(int i) async {
    _segVer++; // আগের সেগমেন্টেশন/AI-র ফল বাতিল
    _ovVer++;
    _aiVer++;
    if (i >= _queue.length) {
      setState(() {
        _cur = null;
        _disposeLater(_dispImg);
        _dispImg = null;
        _resetWork();
      });
      _queue.clear();
      try {
        await FilePicker.platform.clearTemporaryFiles();
      } catch (_) {}
      _toast('এই ব্যাচ শেষ! পরের ব্যাচ বাছাই করুন');
      return;
    }
    setState(() {
      _loading = true;
      _resetWork();
    });
    try {
      final prep = await _prepFor(_queue[i].path!);
      final disp = await _toUiImage(prep.dispRgba, prep.dw, prep.dh);
      if (!mounted) return;
      final old = _dispImg;
      setState(() {
        _cur = prep;
        _dispImg = disp;
        _loading = false;
      });
      _disposeLater(old);
      if (_autoAi && _modelBytes != null) unawaited(_runAi());
      if (i + 1 < _queue.length) {
        final np = _queue[i + 1].path!;
        _nextPath = np;
        _nextPrep = prepareInBackground(np);
        _nextPrep!.then((_) {}, onError: (_) {}); // ত্রুটি পরে ধরা হবে
      }
    } catch (e) {
      if (!mounted) return;
      _toast('${_queue[i].name} পড়া যায়নি, বাদ দিলাম');
      _idx = i + 1;
      await _open(_idx);
    }
  }

  // ------------------------------------------------------------------ AI সবুজ দাগ

  Uint8List _markRgba(Uint8List m) {
    final out = Uint8List(m.length * 4);
    for (var i = 0; i < m.length; i++) {
      if (m[i] == 1) {
        out[i * 4] = 118;
        out[i * 4 + 1] = 255;
        out[i * 4 + 2] = 3;
        out[i * 4 + 3] = 150;
      }
    }
    return out;
  }

  Future<void> _runAi() async {
    final bytes = _modelBytes;
    final prep = _cur;
    if (prep == null) return;
    if (bytes == null) {
      _toast('আগে AI ইম্পোর্ট করুন (উপরে ⋮ মেনু)');
      return;
    }
    final ver = ++_aiVer;
    setState(() => _aiBusy = true);
    try {
      final r = await markerInBackground(MarkerInput(bytes, prep.ww, prep.wh, prep.workRgba));
      if (!mounted || !identical(_cur, prep) || ver != _aiVer) return;
      if (r == null) {
        setState(() => _aiBusy = false);
        _toast('AI নিশ্চিত নয়, নিজে সবুজ দাগ দিন');
        return;
      }
      final mi = await _toUiImage(_markRgba(r), prep.ww, prep.wh);
      if (!mounted || !identical(_cur, prep) || ver != _aiVer) {
        mi.dispose();
        return;
      }
      final old = _markImg;
      setState(() {
        _aiMark = r;
        _markImg = mi;
        _aiBusy = false;
      });
      _disposeLater(old);
      _scheduleSeg();
    } catch (e) {
      if (mounted && identical(_cur, prep)) {
        setState(() => _aiBusy = false);
        _toast('AI চালাতে সমস্যা: $e');
      }
    }
  }

  Future<void> _importModel() async {
    final ds = _ds;
    if (ds == null) return;
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    try {
      final bytes = await File(res.files.single.path!).readAsBytes();
      MarkerNet.parse(bytes);
      await ds.modelFile.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() => _modelBytes = bytes);
      _toast('AI যুক্ত হয়েছে ✓');
      if (_cur != null && _aiMark == null) unawaited(_runAi());
    } catch (e) {
      _toast('এটা AI ফাইল নয়: $e');
    }
  }

  // ------------------------------------------------------------------ আঁকা

  Offset _toWork(Offset pos, Size size) {
    final pr = _cur!;
    final sc = math.min(size.width / pr.ww, size.height / pr.wh);
    final ox = (size.width - pr.ww * sc) / 2;
    final oy = (size.height - pr.wh * sc) / 2;
    final x = ((pos.dx - ox) / sc).clamp(0.0, pr.ww.toDouble()).toDouble();
    final y = ((pos.dy - oy) / sc).clamp(0.0, pr.wh.toDouble()).toDouble();
    return Offset(x, y);
  }

  // পর্দার জায়গা -> জুম-ছাড়া জায়গা
  Offset _toFit(Offset p) => (p - _pan) / _zoom;

  void _clampPan() {
    final s = _canvasSize;
    _pan = Offset(
      _pan.dx.clamp(s.width * (1 - _zoom), 0.0).toDouble(),
      _pan.dy.clamp(s.height * (1 - _zoom), 0.0).toDouble(),
    );
  }

  void _startGesture() {
    final pts = _ptrs.values.toList();
    _gC0 = (pts[0] + pts[1]) / 2;
    _gD0 = math.max(1.0, (pts[0] - pts[1]).distance);
    _gZoom0 = _zoom;
    _gPan0 = _pan;
  }

  void _updateGesture() {
    final pts = _ptrs.values.toList();
    final c = (pts[0] + pts[1]) / 2;
    final d = math.max(1.0, (pts[0] - pts[1]).distance);
    final z = (_gZoom0 * d / _gD0).clamp(1.0, 8.0).toDouble();
    final anchor = (_gC0 - _gPan0) / _gZoom0;
    setState(() {
      _zoom = z;
      _pan = c - anchor * z;
      _clampPan();
    });
  }

  void _cancelDrawing() {
    final a = _active;
    if (a != null) {
      if (a.pts.length <= 3) {
        setState(() => _strokes.remove(a));
        _active = null;
      } else {
        _up();
      }
    }
    if (_boxStart != null) {
      setState(() => _box = null);
      _boxStart = null;
    }
  }

  void _ptrDown(PointerDownEvent e) {
    _ptrs[e.pointer] = e.localPosition;
    if (_ptrs.length >= 2) {
      if (!_gesture) {
        _cancelDrawing();
        _gesture = true;
      }
      _startGesture();
    } else if (!_gesture) {
      _down(_toFit(e.localPosition), _canvasSize);
    }
  }

  void _ptrMove(PointerMoveEvent e) {
    if (!_ptrs.containsKey(e.pointer)) return;
    _ptrs[e.pointer] = e.localPosition;
    if (_gesture) {
      if (_ptrs.length >= 2) _updateGesture();
    } else {
      _move(_toFit(e.localPosition), _canvasSize);
    }
  }

  void _ptrUp(PointerEvent e) {
    if (_ptrs.remove(e.pointer) == null) return;
    if (_gesture) {
      if (_ptrs.isEmpty) {
        _gesture = false;
      } else if (_ptrs.length >= 2) {
        _startGesture();
      }
    } else {
      _up();
    }
  }

  void _down(Offset pos, Size size) {
    if (_cur == null || _loading) return;
    final pt = _toWork(pos, size);
    if (_tool == Tool.box) {
      _boxStart = pt;
      setState(() => _box = Rect.fromPoints(pt, pt));
    } else {
      final s = _Stroke(_tool, _brush)..pts.add(pt);
      _active = s;
      setState(() => _strokes.add(s));
    }
  }

  void _move(Offset pos, Size size) {
    if (_cur == null) return;
    final pt = _toWork(pos, size);
    if (_tool == Tool.box && _boxStart != null) {
      setState(() => _box = Rect.fromPoints(_boxStart!, pt));
    } else if (_active != null) {
      setState(() => _active!.pts.add(pt));
    }
  }

  void _up() {
    if (_cur == null) return;
    var seg = false;
    var edit = false;
    if (_tool == Tool.box && _boxStart != null) {
      final b = _box;
      if (b == null || b.width < 10 || b.height < 10) {
        setState(() => _box = null);
      }
      _boxStart = null;
      seg = true;
    }
    final a = _active;
    if (a != null) {
      _active = null;
      if (a.tool == Tool.white || a.tool == Tool.black) {
        edit = true;
      } else {
        seg = true;
      }
    }
    if (seg) {
      _scheduleSeg();
    } else if (edit) {
      _rebuildOverlay();
    }
  }

  void _undo() {
    Tool? kind;
    setState(() {
      if (_strokes.isNotEmpty) {
        kind = _strokes.removeLast().tool;
      } else if (_aiMark != null) {
        _aiMark = null;
        _disposeLater(_markImg);
        _markImg = null;
        kind = Tool.fg;
      } else {
        _box = null;
        kind = Tool.box;
      }
    });
    if (kind == Tool.white || kind == Tool.black) {
      _rebuildOverlay();
    } else {
      _scheduleSeg();
    }
  }

  void _clear() {
    setState(() {
      _strokes.clear();
      _box = null;
      _aiMark = null;
      _disposeLater(_markImg);
      _markImg = null;
    });
    _scheduleSeg();
  }

  // ------------------------------------------------------------------ সেগমেন্টেশন

  void _scheduleSeg() {
    final ver = ++_segVer;
    _segFuture = _runSeg(ver);
  }

  SegInput _buildInput(Prepared pr) {
    final w = pr.ww, h = pr.wh;
    final seeds = Uint8List(w * h);
    final ai = _aiMark;
    if (ai != null) {
      for (var i = 0; i < seeds.length; i++) {
        if (ai[i] == 1) seeds[i] = 1;
      }
    }
    // আপনার দাগ AI-র দাগের ওপরে বসে (লাল দিলে AI-র সবুজ মুছে যায়)
    for (final s in _strokes) {
      if (s.tool != Tool.fg && s.tool != Tool.bg) continue;
      final v = s.tool == Tool.fg ? 1 : 2;
      for (var i = 0; i < s.pts.length; i++) {
        final a = s.pts[i];
        _stamp(seeds, w, h, a.dx, a.dy, s.r, v);
        if (i > 0) {
          final b = s.pts[i - 1];
          final d = (a - b).distance;
          final steps = (d / math.max(1.0, s.r * 0.5)).ceil();
          for (var k = 1; k < steps; k++) {
            final t = k / steps;
            _stamp(seeds, w, h, b.dx + (a.dx - b.dx) * t, b.dy + (a.dy - b.dy) * t, s.r, v);
          }
        }
      }
    }
    List<int>? box;
    final b = _box;
    if (b != null) {
      final x0 = b.left.floor().clamp(0, w - 2).toInt();
      final y0 = b.top.floor().clamp(0, h - 2).toInt();
      final x1 = b.right.ceil().clamp(x0 + 1, w).toInt();
      final y1 = b.bottom.ceil().clamp(y0 + 1, h).toInt();
      box = [x0, y0, x1, y1];
    }
    return SegInput(w, h, pr.workRgba, seeds, box);
  }

  Float32List _editRecords() {
    final l = <double>[];
    for (final s in _strokes) {
      if (s.tool != Tool.white && s.tool != Tool.black) continue;
      l.add(s.tool == Tool.white ? 1 : 2);
      l.add(s.r);
      l.add(s.pts.length.toDouble());
      for (final q in s.pts) {
        l.add(q.dx);
        l.add(q.dy);
      }
    }
    return Float32List.fromList(l);
  }

  // সেগমেন্টেশনের ফলের ওপর সাদা/কালো ব্রাশ বসানো
  Uint8List _viewMask(SegResult seg) {
    final m = Uint8List.fromList(seg.mask);
    final rec = _editRecords();
    if (rec.isNotEmpty) applyEdits(m, seg.w, seg.h, 1.0, rec, 1);
    return m;
  }

  Future<void> _runSeg(int ver) async {
    final pr = _cur;
    if (pr == null) return;
    final hasFg = _aiMark != null || _strokes.any((s) => s.tool == Tool.fg);
    if (_box == null && !hasFg) {
      if (!mounted) return;
      _ovVer++;
      final o = _overlay, m = _maskImg;
      setState(() {
        _seg = null;
        _overlay = null;
        _maskImg = null;
        _busy = false;
      });
      _disposeLater(o, m);
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await segmentInBackground(_buildInput(pr));
      if (ver != _segVer || !mounted) return;
      setState(() {
        _seg = res;
        _busy = false;
      });
      await _rebuildOverlay();
    } catch (e) {
      if (mounted && ver == _segVer) {
        setState(() => _busy = false);
        _toast('সেগমেন্টেশনে সমস্যা: $e');
      }
    }
  }

  Future<void> _rebuildOverlay() async {
    final seg = _seg;
    if (seg == null || !mounted) return;
    final ver = ++_ovVer;
    final view = _viewMask(seg);
    final w = seg.w, h = seg.h;
    final tint = Uint8List(w * h * 4);
    final bw = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        final on = view[i] == 1;
        var edge = false;
        if (on) {
          edge = x == 0 ||
              y == 0 ||
              x == w - 1 ||
              y == h - 1 ||
              view[i - 1] == 0 ||
              view[i + 1] == 0 ||
              view[i - w] == 0 ||
              view[i + w] == 0;
        }
        if (edge) {
          tint[i * 4] = 255;
          tint[i * 4 + 1] = 235;
          tint[i * 4 + 2] = 59;
          tint[i * 4 + 3] = 255;
        } else if (on) {
          tint[i * 4] = 0;
          tint[i * 4 + 1] = 230;
          tint[i * 4 + 2] = 118;
          tint[i * 4 + 3] = 95;
        }
        final v = on ? 255 : 0;
        bw[i * 4] = v;
        bw[i * 4 + 1] = v;
        bw[i * 4 + 2] = v;
        bw[i * 4 + 3] = 255;
      }
    }
    final ov = await _toUiImage(tint, w, h);
    final mk = await _toUiImage(bw, w, h);
    if (ver != _ovVer || !mounted) {
      ov.dispose();
      mk.dispose();
      return;
    }
    final oldOv = _overlay, oldMk = _maskImg;
    setState(() {
      _overlay = ov;
      _maskImg = mk;
    });
    _disposeLater(oldOv, oldMk);
  }

  // ------------------------------------------------------------------ সেভ

  Future<void> _saveNext() async {
    final prep = _cur;
    final ds = _ds;
    if (prep == null || ds == null) return;
    if (_segFuture != null) await _segFuture;
    final seg = _seg;
    if (seg == null) {
      _toast('আগে সবুজ দাগ দিন (বা AI দাগ / বক্স)');
      return;
    }
    final qf = _queue[_idx];
    final name = qf.name;
    final size = qf.size;

    // আপনি নিজে সবুজ দাগ দিলে তবেই AI-র শেখার ডেটা হিসেবে জমা হবে
    Uint8List? marks;
    if (_strokes.any((s) => s.tool == Tool.fg)) {
      final inp = _buildInput(prep);
      marks = Uint8List(prep.ww * prep.wh);
      for (var i = 0; i < marks.length; i++) {
        if (inp.seeds[i] == 1) marks[i] = 1;
      }
    }
    final input = ExportInput(
      prep.sw,
      prep.sh,
      prep.rgb,
      seg.w,
      seg.h,
      seg.mask,
      seg.table,
      edits: _editRecords(),
      workRgba: prep.workRgba,
      marks: marks,
      subject: _viewMask(seg),
    );
    _pendingSaves++;
    final fut = () async {
      try {
        final r = await exportInBackground(input);
        await ds.save(
          name: name,
          size: size,
          jpg: r.jpg,
          png: r.png,
          markJpg: r.markJpg,
          markPng: r.markPng,
          subjectPng: r.subjectPng,
        );
      } catch (e) {
        _toast('সেভ হয়নি: $name ($e)');
      } finally {
        _pendingSaves--;
        if (mounted) setState(() {});
      }
    }();
    _saves.add(fut);
    setState(() {});
    _idx++;
    await _open(_idx);
  }

  Future<void> _skip() async {
    if (_cur == null) return;
    _idx++;
    await _open(_idx);
  }

  Future<void> _exportZip() async {
    final ds = _ds;
    if (ds == null || ds.count == 0) {
      _toast('এখনো কিছু সেভ হয়নি');
      return;
    }
    setState(() => _exporting = true);
    try {
      await Future.wait(_saves);
      final zips = await ds.exportZips();
      await Share.shareXFiles([for (final z in zips) XFile(z)], text: 'Mask Maker dataset');
    } catch (e) {
      _toast('ZIP করা যায়নি: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _info() {
    final ds = _ds;
    if (ds == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ডেটাসেট'),
        content: Text('মোট ছবি+মাস্ক: ${ds.count}\n'
            '  DIS-TR (train): ${ds.countSplit('TR')}\n'
            '  DIS-VD (val): ${ds.countSplit('VD')}\n'
            'AI-র জন্য সবুজ দাগ জমেছে: ${ds.markCount}\n'
            'AI: ${_modelBytes == null ? 'যুক্ত নেই' : 'যুক্ত আছে ✓'}\n\n'
            'জায়গা: অ্যাপের নিজস্ব স্টোরেজ\n${pth.basename(ds.root.path)} / ${pth.basename(ds.marksRoot.path)}\n\n'
            'অ্যাপ আনইনস্টল করলে এগুলো মুছে যাবে, তাই নিয়মিত ZIP এক্সপোর্ট করে রাখুন।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ঠিক আছে')),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final ds = _ds;
    final left = _cur == null ? 0 : _queue.length - _idx;
    return Scaffold(
      appBar: AppBar(
        title: Text(ds == null ? 'Mask Maker' : 'সেভ: ${ds.count}   বাকি: $left'),
        actions: [
          if (_pendingSaves > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Center(child: Text('⏳$_pendingSaves')),
            ),
          IconButton(
            tooltip: 'ছবি বাছাই',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: ds == null ? null : _pick,
          ),
          IconButton(
            tooltip: 'ZIP এক্সপোর্ট',
            icon: _exporting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            onPressed: (ds == null || _exporting) ? null : _exportZip,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'ai') _importModel();
              if (v == 'info') _info();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'ai',
                child: Text(_modelBytes == null ? 'AI ইম্পোর্ট (ফাইল বাছুন)' : 'AI বদলান (ইম্পোর্ট) ✓'),
              ),
              const PopupMenuItem(value: 'info', child: Text('তথ্য')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _canvas()),
            _toolbar(),
          ],
        ),
      ),
    );
  }

  Widget _canvas() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final pr = _cur;
    final disp = _dispImg;
    if (pr == null || disp == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'একসাথে ১০০-২০০টা ছবি বাছাই করুন।\nআগে করা ছবি নিজে থেকে বাদ যাবে।',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _ds == null ? null : _pick,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('ছবি বাছাই করুন'),
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(builder: (context, bc) {
      final size = Size(bc.maxWidth, bc.maxHeight);
      _canvasSize = size;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _ptrDown,
        onPointerMove: _ptrMove,
        onPointerUp: _ptrUp,
        onPointerCancel: _ptrUp,
        child: CustomPaint(
          size: size,
          painter: _CanvasPainter(
            zoom: _zoom,
            pan: _pan,
            disp: disp,
            overlay: _overlay,
            maskImg: _maskImg,
            markImg: _markImg,
            maskOnly: _maskOnly,
            ww: pr.ww,
            wh: pr.wh,
            strokes: _strokes,
            box: _box,
          ),
        ),
      );
    });
  }

  Widget _chip(Tool t, String label, IconData icon, Color? color) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        avatar: Icon(icon, size: 18, color: color),
        label: Text(label),
        selected: _tool == t,
        onSelected: (_) => setState(() => _tool = t),
      ),
    );
  }

  Widget _toolbar() {
    final hasImg = _cur != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasImg && _strokes.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'সাবজেক্টের ভেতরে মোটা করে সবুজ দাগ দিন (কিনারায় নয়)। বাকি সব ব্যাকগ্রাউন্ড ধরা হবে। দুই আঙুলে জুম/সরান।',
                style: TextStyle(fontSize: 12),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _chip(Tool.fg, 'সবুজ', Icons.brush, Colors.greenAccent),
                      _chip(Tool.bg, 'লাল (ঐচ্ছিক)', Icons.brush, Colors.redAccent),
                      _chip(Tool.box, 'বক্স', Icons.crop_square, null),
                      _chip(Tool.white, 'সাদা ব্রাশ', Icons.edit, Colors.white),
                      _chip(Tool.black, 'কালো ব্রাশ', Icons.edit, Colors.grey),
                    ],
                  ),
                ),
              ),
              if (_busy || _aiBusy)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.circle, size: 10),
              Expanded(
                child: Slider(
                  value: _brush,
                  min: 2,
                  max: 14,
                  onChanged: (v) => setState(() => _brush = v),
                ),
              ),
              const Icon(Icons.circle, size: 20),
            ],
          ),
          Row(
            children: [
              IconButton(tooltip: 'Undo', onPressed: hasImg ? _undo : null, icon: const Icon(Icons.undo)),
              IconButton(tooltip: 'সব মুছুন', onPressed: hasImg ? _clear : null, icon: const Icon(Icons.layers_clear)),
              IconButton(
                tooltip: 'জুম ঠিক করুন',
                onPressed: (hasImg && _zoom != 1)
                    ? () => setState(() {
                          _zoom = 1;
                          _pan = Offset.zero;
                        })
                    : null,
                icon: const Icon(Icons.zoom_out_map),
              ),
              FilterChip(
                avatar: const Icon(Icons.contrast, size: 18),
                label: const Text('মাস্ক দেখুন'),
                selected: _maskOnly,
                onSelected: hasImg ? (v) => setState(() => _maskOnly = v) : null,
              ),
              const Spacer(),
              const Text('Auto AI'),
              Switch(value: _autoAi, onChanged: (v) => setState(() => _autoAi = v)),
            ],
          ),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: hasImg ? _runAi : null,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('AI দাগ'),
              ),
              const Spacer(),
              TextButton(onPressed: hasImg ? _skip : null, child: const Text('Skip')),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: (hasImg && _seg != null) ? _saveNext : null,
                icon: const Icon(Icons.check),
                label: const Text('Save ➜ Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.zoom,
    required this.pan,
    required this.disp,
    required this.overlay,
    required this.maskImg,
    required this.markImg,
    required this.maskOnly,
    required this.ww,
    required this.wh,
    required this.strokes,
    required this.box,
  });

  final double zoom;
  final Offset pan;
  final ui.Image disp;
  final ui.Image? overlay;
  final ui.Image? maskImg;
  final ui.Image? markImg;
  final bool maskOnly;
  final int ww, wh;
  final List<_Stroke> strokes;
  final Rect? box;

  Rect _full(ui.Image i) => Rect.fromLTWH(0, 0, i.width.toDouble(), i.height.toDouble());

  Color _color(Tool t) {
    switch (t) {
      case Tool.fg:
        return const Color(0xAA00E676);
      case Tool.bg:
        return const Color(0xAAFF1744);
      case Tool.white:
        return const Color(0xBBFFFFFF);
      case Tool.black:
        return const Color(0xCC000000);
      case Tool.box:
        return const Color(0x00000000);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sc = math.min(size.width / ww, size.height / wh);
    final dw = ww * sc, dh = wh * sc;
    final ox = (size.width - dw) / 2, oy = (size.height - dh) / 2;
    final dst = Rect.fromLTWH(ox, oy, dw, dh);
    final imgPaint = Paint()..filterQuality = FilterQuality.medium;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(zoom);

    canvas.drawImageRect(disp, _full(disp), dst, imgPaint);
    if (maskOnly && maskImg != null) {
      canvas.drawImageRect(maskImg!, _full(maskImg!), dst, imgPaint);
    } else if (!maskOnly) {
      if (overlay != null) canvas.drawImageRect(overlay!, _full(overlay!), dst, imgPaint);
      if (markImg != null) canvas.drawImageRect(markImg!, _full(markImg!), dst, imgPaint);
    }

    canvas.save();
    canvas.clipRect(dst);
    for (final s in strokes) {
      // মাস্ক দেখার সময় সবুজ/লাল দাগ লুকানো, শুধু সাদা/কালো ব্রাশ থাকবে
      if (maskOnly && s.tool != Tool.white && s.tool != Tool.black) continue;
      final color = _color(s.tool);
      final width = 2 * s.r * sc;
      if (s.pts.length == 1) {
        final pt = s.pts.first;
        canvas.drawCircle(
          Offset(ox + pt.dx * sc, oy + pt.dy * sc),
          width / 2,
          Paint()..color = color,
        );
      } else {
        final path = Path();
        for (var i = 0; i < s.pts.length; i++) {
          final pt = Offset(ox + s.pts[i].dx * sc, oy + s.pts[i].dy * sc);
          if (i == 0) {
            path.moveTo(pt.dx, pt.dy);
          } else {
            path.lineTo(pt.dx, pt.dy);
          }
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }
    final b = maskOnly ? null : box;
    if (b != null) {
      canvas.drawRect(
        Rect.fromLTRB(ox + b.left * sc, oy + b.top * sc, ox + b.right * sc, oy + b.bottom * sc),
        Paint()
          ..color = Colors.cyanAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / zoom,
      );
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) => true;
}
