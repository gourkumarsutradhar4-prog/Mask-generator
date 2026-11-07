import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'dataset.dart';
import 'segmenter.dart';

void main() => runApp(const MaskMakerApp());

class MaskMakerApp extends StatelessWidget {
  const MaskMakerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Mask Maker',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        home: const HomePage(),
      );
}

/// একটা আঁচড়: label 1 = সাবজেক্ট, 2 = ব্যাকগ্রাউন্ড
class Stroke {
  Stroke(this.label, this.brush);
  final int label;
  final double brush;
  final List<Offset> pts = []; // ছোট ছবির পিক্সেল স্থানাঙ্কে
}

/// দাগ দেখে মাস্ক বানায় (ব্যাকগ্রাউন্ড আইসোলেটে চলে), সাথে দেখানোর জন্য দুটো ছবি
Map<String, dynamic> _segment(Map<String, dynamic> a) {
  final small = img.decodePng(a['png'] as Uint8List)!;
  final fg = Segmenter.run(
    image: small,
    seeds: a['seeds'] as Uint8List,
    edgeWeight: (a['edge'] as num).toDouble(),
  );
  final w = small.width;
  final h = small.height;
  final overlay = img.Image(width: w, height: h, numChannels: 4);
  final maskImg = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final on = fg[y * w + x] == 255;
      if (on) overlay.setPixelRgba(x, y, 0, 255, 0, 110);
      final v = on ? 255 : 0;
      maskImg.setPixelRgb(x, y, v, v, v);
    }
  }
  return {
    'mask': fg,
    'overlay': Uint8List.fromList(img.encodePng(overlay)),
    'maskPng': Uint8List.fromList(img.encodePng(maskImg)),
  };
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = ImagePicker();
  DatasetStore? _store;
  List<XFile> _files = [];
  int _index = 0;
  int _skipped = 0;

  Uint8List? _smallPng; // হিসাবের জন্য ছোট ছবি
  Uint8List? _viewJpg; // জুম করে দেখার জন্য বড় ছবি
  Uint8List? _fixed; // ছবি ঘোরানো থাকলে সোজা করা নতুন JPG এখানে থাকে
  String _ext = 'jpg';
  int _w = 0, _h = 0, _sw = 0, _sh = 0;

  final List<Stroke> _strokes = [];
  Stroke? _current;
  int _tool = 1;
  double _edgeWeight = 6;
  double _brush = 5;

  // জুম: false = আঁকার মোড, true = জুম/সরানোর মোড
  bool _moveMode = false;
  final TransformationController _tc = TransformationController();

  Uint8List? _mask;
  Uint8List? _overlayPng;
  Uint8List? _maskPng;
  bool _showMask = false;

  bool _loading = false;
  bool _working = false;
  bool _dirty = false;
  String _status = 'স্টোরেজ তৈরি হচ্ছে...';

  @override
  void initState() {
    super.initState();
    _initStore();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _initStore() async {
    try {
      final s = await DatasetStore.open();
      if (!mounted) return;
      setState(() {
        _store = s;
        _status = 'ডেটাসেটে এখন ${s.total} জোড়া আছে। ছবি বেছে নিন';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'স্টোরেজ ত্রুটি: $e');
    }
  }

  Future<void> _pickImages() async {
    final store = _store;
    if (store == null) return;
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    // আগেই সেভ করা ছবি (একই নাম) বাদ দিই, যাতে কাজ দ্বিতীয়বার না হয়
    final fresh = <XFile>[];
    var skipped = 0;
    for (final x in picked) {
      if (store.exists(DatasetStore.safeStem(x.name))) {
        skipped++;
      } else {
        fresh.add(x);
      }
    }
    if (fresh.isEmpty) {
      setState(() => _status = 'সবগুলো ছবি আগেই সেভ করা আছে ($skipped টা)');
      return;
    }
    setState(() {
      _files = fresh;
      _index = 0;
      _skipped = skipped;
    });
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _status = 'ছবি লোড হচ্ছে...';
      _smallPng = null;
      _viewJpg = null;
      _fixed = null;
      _mask = null;
      _overlayPng = null;
      _maskPng = null;
      _showMask = false;
      _moveMode = false;
      _tc.value = Matrix4.identity();
      _strokes.clear();
    });
    try {
      final r = await compute(prepareImage, _files[_index].path);
      if (!mounted) return;
      setState(() {
        _w = r['w'] as int;
        _h = r['h'] as int;
        _sw = r['sw'] as int;
        _sh = r['sh'] as int;
        _smallPng = r['png'] as Uint8List;
        _viewJpg = r['view'] as Uint8List;
        _fixed = r['fixed'] as Uint8List?;
        _ext = r['ext'] as String;
        _status =
            'ছবি ${_index + 1}/${_files.length} (আগে করা $_skipped টা বাদ)। সবুজ = সাবজেক্ট, লাল = ব্যাকগ্রাউন্ড। জুম করতে ওপরের হাতের বাটন চাপুন';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'ত্রুটি: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// আঁচড়গুলোকে পিক্সেলের seed ম্যাপে রূপ দেয়
  Uint8List _rasterSeeds() {
    final seeds = Uint8List(_sw * _sh);
    void stamp(Offset c, int label, int rad) {
      final cx = c.dx.round();
      final cy = c.dy.round();
      for (var dy = -rad; dy <= rad; dy++) {
        for (var dx = -rad; dx <= rad; dx++) {
          if (dx * dx + dy * dy > rad * rad) continue;
          final x = cx + dx;
          final y = cy + dy;
          if (x < 0 || y < 0 || x >= _sw || y >= _sh) continue;
          seeds[y * _sw + x] = label;
        }
      }
    }

    for (final s in _strokes) {
      final rad = s.brush.round();
      Offset? prev;
      for (final p in s.pts) {
        final from = prev ?? p;
        final steps = math.max(1, (p - from).distance.ceil());
        for (var i = 1; i <= steps; i++) {
          stamp(from + (p - from) * (i / steps), s.label, rad);
        }
        prev = p;
      }
    }
    return seeds;
  }

  Future<void> _runSegment() async {
    if (_smallPng == null || _strokes.isEmpty) return;
    if (_working) {
      _dirty = true;
      return;
    }
    setState(() {
      _working = true;
      _status = 'মাস্ক তৈরি হচ্ছে...';
    });
    try {
      final r = await compute(_segment, <String, dynamic>{
        'png': _smallPng!,
        'seeds': _rasterSeeds(),
        'edge': _edgeWeight,
      });
      if (!mounted) return;
      setState(() {
        _mask = r['mask'] as Uint8List;
        _overlayPng = r['overlay'] as Uint8List;
        _maskPng = r['maskPng'] as Uint8List;
        _status = 'ঠিক না হলে আরও দাগ দিন, ঠিক থাকলে সেভ চাপুন';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'ত্রুটি: $e');
    } finally {
      if (mounted) setState(() => _working = false);
      if (_dirty && mounted) {
        _dirty = false;
        _runSegment();
      }
    }
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
    if (_strokes.isEmpty) {
      setState(() {
        _mask = null;
        _overlayPng = null;
        _maskPng = null;
      });
    } else {
      _runSegment();
    }
  }

  void _reset() {
    setState(() {
      _strokes.clear();
      _mask = null;
      _overlayPng = null;
      _maskPng = null;
      _status = 'নতুন করে দাগ দিন';
    });
  }

  Future<void> _save() async {
    final mask = _mask;
    final store = _store;
    if (mask == null || store == null) return;

    // খালি বা পুরো সাদা মাস্ক ট্রেইনিংয়ে ভুল ঢোকায়, তাই সেভ করতে দিই না
    var white = 0;
    for (final v in mask) {
      if (v == 255) white++;
    }
    if (white == 0 || white == mask.length) {
      setState(() => _status = 'মাস্ক পুরো কালো বা পুরো সাদা, আগে দাগ ঠিক করুন');
      return;
    }

    setState(() {
      _loading = true;
      _status = 'সেভ হচ্ছে...';
    });
    try {
      final src = _files[_index];
      final maskPng = await compute(fullMaskPng, <String, dynamic>{
        'mask': mask,
        'sw': _sw,
        'sh': _sh,
        'w': _w,
        'h': _h,
      });
      final bytes = _fixed ?? await File(src.path).readAsBytes();
      store.save(
        stem: DatasetStore.safeStem(src.name),
        imageExt: _ext,
        imageBytes: bytes,
        maskPng: maskPng,
      );
      // পিকার যে অস্থায়ী কপি বানিয়েছিল সেটা মুছে জায়গা বাঁচাই
      try {
        if (src.path.contains('/cache/')) File(src.path).deleteSync();
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
      await _next();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _status = 'সেভে ত্রুটি: $e';
        });
      }
    }
  }

  Future<void> _next() async {
    if (_index + 1 < _files.length) {
      _index++;
      await _load();
    } else {
      setState(() {
        _smallPng = null;
        _viewJpg = null;
        _status = 'এই ব্যাচ শেষ! ডেটাসেটে এখন ${_store?.total ?? 0} জোড়া আছে';
      });
    }
  }

  Future<void> _exportZip() async {
    final store = _store;
    if (store == null) return;
    if (store.total == 0) {
      setState(() => _status = 'আগে কিছু ছবি সেভ করুন');
      return;
    }
    setState(() {
      _loading = true;
      _status = 'ZIP বানানো হচ্ছে। ডেটাসেট বড় হলে কয়েক মিনিট লাগবে, অ্যাপ খোলা রাখুন';
    });
    try {
      final tmp = await getTemporaryDirectory();
      final parts = await compute(makeZips, <String, dynamic>{
        'root': store.root.path,
        'out': '${tmp.path}/dis_export',
      });
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = '${parts.length}টা ZIP তৈরি হয়েছে';
      });
      await Share.shareXFiles(parts.map((p) => XFile(p)).toList());
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _status = 'ZIP-এ ত্রুটি: $e';
        });
      }
    }
  }

  void _showInfo(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ঠিক আছে'),
          ),
        ],
      ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mask Maker'),
        actions: [
          Center(
            child: Text('TR ${store?.trCount ?? 0} · VD ${store?.vdCount ?? 0}'),
          ),
          IconButton(
            tooltip: 'ছবি বেছে নিন',
            icon: const Icon(Icons.photo_library),
            onPressed: (_loading || store == null) ? null : _pickImages,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (store == null) return;
              if (v == 'zip') _exportZip();
              if (v == 'check') _showInfo('ডেটাসেট যাচাই', store.verify());
              if (v == 'path') _showInfo('ডেটাসেট কোথায় আছে', store.root.path);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'zip', child: Text('ZIP বানিয়ে শেয়ার করুন')),
              PopupMenuItem(value: 'check', child: Text('ডেটাসেট যাচাই করুন')),
              PopupMenuItem(value: 'path', child: Text('ডেটাসেটের জায়গা দেখান')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_status, textAlign: TextAlign.center),
            ),
            Expanded(
              child: Center(
                child: _smallPng == null
                    ? (_loading
                        ? const CircularProgressIndicator()
                        : FilledButton.icon(
                            onPressed: store == null ? null : _pickImages,
                            icon: const Icon(Icons.photo_library),
                            label: const Text('ছবি বেছে নিন'),
                          ))
                    : _canvas(),
              ),
            ),
            if (_smallPng != null) _controls(),
          ],
        ),
      ),
    );
  }

  Widget _canvas() {
    return AspectRatio(
      aspectRatio: _sw / _sh,
      child: LayoutBuilder(builder: (context, c) {
        final scale = _sw / c.maxWidth; // স্ক্রিন → ছবির পিক্সেল (জুম ছাড়া)
        final layers = SizedBox(
          width: c.maxWidth,
          height: c.maxHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(_viewJpg ?? _smallPng!,
                  fit: BoxFit.fill, gaplessPlayback: true),
              if (_showMask && _maskPng != null)
                Image.memory(_maskPng!, fit: BoxFit.fill, gaplessPlayback: true)
              else if (_overlayPng != null)
                Image.memory(_overlayPng!,
                    fit: BoxFit.fill, gaplessPlayback: true),
              if (!(_showMask && _maskPng != null))
                CustomPaint(painter: _StrokePainter(_strokes, 1 / scale)),
            ],
          ),
        );

        final Widget zoomable;
        if (_moveMode) {
          // জুম/সরানোর মোড: দুই আঙুলে জুম, এক আঙুলে সরান
          zoomable = InteractiveViewer(
            transformationController: _tc,
            minScale: 1,
            maxScale: 8,
            child: IgnorePointer(child: layers),
          );
        } else {
          // আঁকার মোড: জুমের অবস্থা ধরে রেখে এক আঙুলে দাগ দিন
          zoomable = Transform(
            transform: _tc.value,
            child: GestureDetector(
              onPanStart: (d) {
                final s = Stroke(_tool, _brush)..pts.add(d.localPosition * scale);
                _current = s;
                setState(() => _strokes.add(s));
              },
              onPanUpdate: (d) {
                _current?.pts.add(d.localPosition * scale);
                setState(() {});
              },
              onPanEnd: (_) {
                _current = null;
                _runSegment();
              },
              child: layers,
            ),
          );
        }

        return Stack(
          children: [
            Positioned.fill(child: ClipRect(child: zoomable)),
            Positioned(
              top: 6,
              right: 6,
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'আঁকুন',
                    isSelected: !_moveMode,
                    icon: const Icon(Icons.brush),
                    onPressed: () => setState(() => _moveMode = false),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'জুম/সরান',
                    isSelected: _moveMode,
                    icon: const Icon(Icons.pan_tool_alt),
                    onPressed: () => setState(() => _moveMode = true),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'জুম রিসেট',
                    icon: const Icon(Icons.zoom_out_map),
                    onPressed: () => setState(() => _tc.value = Matrix4.identity()),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _controls() {
    final canSave = _mask != null && !_working && !_loading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                  value: 1,
                  label: Text('সাবজেক্ট'),
                  icon: Icon(Icons.circle, color: Colors.green)),
              ButtonSegment(
                  value: 2,
                  label: Text('ব্যাকগ্রাউন্ড'),
                  icon: Icon(Icons.circle, color: Colors.red)),
            ],
            selected: {_tool},
            onSelectionChanged: (s) => setState(() => _tool = s.first),
          ),
          Row(children: [
            const SizedBox(width: 90, child: Text('কিনারার জোর')),
            Expanded(
              child: Slider(
                value: _edgeWeight,
                min: 0,
                max: 20,
                onChanged: (v) => setState(() => _edgeWeight = v),
                onChangeEnd: (_) => _runSegment(),
              ),
            ),
          ]),
          Row(children: [
            const SizedBox(width: 90, child: Text('ব্রাশ')),
            Expanded(
              child: Slider(
                value: _brush,
                min: 1,
                max: 15,
                onChanged: (v) => setState(() => _brush = v),
              ),
            ),
          ]),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                  tooltip: 'আনডু',
                  onPressed: _strokes.isEmpty ? null : _undo,
                  icon: const Icon(Icons.undo)),
              IconButton(
                  tooltip: 'রিসেট',
                  onPressed: _strokes.isEmpty ? null : _reset,
                  icon: const Icon(Icons.delete_outline)),
              IconButton(
                  tooltip: 'এই ছবি বাদ দিন',
                  onPressed: _loading ? null : _next,
                  icon: const Icon(Icons.skip_next)),
              Row(children: [
                const Text('মাস্ক'),
                Switch(
                    value: _showMask,
                    onChanged: (v) => setState(() => _showMask = v)),
              ]),
              FilledButton(
                onPressed: canSave ? _save : null,
                child: const Text('সেভ'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes, this.k);
  final List<Stroke> strokes;
  final double k; // ছবির পিক্সেল → স্ক্রিন

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = (s.label == 1 ? Colors.greenAccent : Colors.redAccent)
            .withAlpha(200)
        ..strokeWidth = s.brush * 2 * k
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < s.pts.length; i++) {
        final p = s.pts[i] * k;
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
          path.lineTo(p.dx + 0.01, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}
