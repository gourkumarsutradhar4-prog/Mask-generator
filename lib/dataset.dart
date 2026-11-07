import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// প্রতি ১০টা ছবির ১টা যাবে DIS-VD (ভ্যালিডেশন) ফোল্ডারে, বাকিগুলো DIS-TR-এ
const int kValEvery = 10;

/// ZIP-এর একেকটা অংশের সর্বোচ্চ মাপ। ৪ GB-এর নিচে রাখা, যাতে সব ZIP টুলে খোলে
const int kZipPartBytes = 3500 * 1000 * 1000;

const String kRootName = 'DIS-Dataset';

/// দাগ দেওয়া আর মাস্ক হিসাবের ছোট ছবির বড় দিক। বাড়ালে সীমানা নিখুঁত হয়, কিন্তু ধীর হয়
const int kWorkSide = 512;

/// জুম করে দেখার ছবির বড় দিক
const int kViewSide = 1600;

/// ডেটাসেট ফোল্ডার: DIS-Dataset/DIS-TR/{im,gt} আর DIS-Dataset/DIS-VD/{im,gt}
class DatasetStore {
  DatasetStore._(this.root);
  final Directory root;
  int trCount = 0;
  int vdCount = 0;

  int get total => trCount + vdCount;

  static Future<DatasetStore> open() async {
    final ext = await getExternalStorageDirectory();
    final base = ext ?? await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/$kRootName');
    for (final split in ['DIS-TR', 'DIS-VD']) {
      for (final kind in ['im', 'gt']) {
        await Directory('${root.path}/$split/$kind').create(recursive: true);
      }
    }
    return DatasetStore._(root)..refresh();
  }

  String _dir(String split, String kind) => '${root.path}/$split/$kind';

  void refresh() {
    trCount = _count('DIS-TR');
    vdCount = _count('DIS-VD');
  }

  int _count(String split) {
    final d = Directory(_dir(split, 'gt'));
    if (!d.existsSync()) return 0;
    return d.listSync().whereType<File>().where((f) => f.path.endsWith('.png')).length;
  }

  /// ফাইলের নাম থেকে নিরাপদ নাম (শুধু A-Z a-z 0-9 _ -)
  static String safeStem(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final clean = base.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (clean == base && clean.isNotEmpty) return clean;
    // নামে অন্য অক্ষর বা স্পেস থাকলে হ্যাশ জুড়ে দিই, যাতে দুই ছবির নাম এক না হয়
    var h = 2166136261;
    for (final c in base.codeUnits) {
      h = ((h ^ c) * 16777619) & 0xFFFFFFFF;
    }
    final head = clean.isEmpty ? 'img' : clean;
    return '${head}_${h.toRadixString(16)}';
  }

  bool exists(String stem) =>
      File('${_dir('DIS-TR', 'gt')}/$stem.png').existsSync() ||
      File('${_dir('DIS-VD', 'gt')}/$stem.png').existsSync();

  /// ছবি আর মাস্ক একসাথে সেভ করে। একটা ব্যর্থ হলে দুটোই মুছে দেয়, আধা-জোড়া থাকে না
  String save({
    required String stem,
    required String imageExt,
    required Uint8List imageBytes,
    required Uint8List maskPng,
  }) {
    final toVal = (total + 1) % kValEvery == 0;
    final split = toVal ? 'DIS-VD' : 'DIS-TR';
    final gt = File('${_dir(split, 'gt')}/$stem.png');
    final im = File('${_dir(split, 'im')}/$stem.$imageExt');
    try {
      gt.writeAsBytesSync(maskPng, flush: true);
      im.writeAsBytesSync(imageBytes, flush: true);
    } catch (_) {
      if (gt.existsSync()) gt.deleteSync();
      if (im.existsSync()) im.deleteSync();
      rethrow;
    }
    if (toVal) {
      vdCount++;
    } else {
      trCount++;
    }
    return split;
  }

  static String _stemOf(String path) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// im আর gt ফোল্ডারের নাম মিলছে কিনা দেখে
  String verify() {
    final problems = <String>[];
    var pairs = 0;
    for (final split in ['DIS-TR', 'DIS-VD']) {
      final ims = Directory(_dir(split, 'im')).listSync().whereType<File>().map((f) => _stemOf(f.path)).toSet();
      final gts = Directory(_dir(split, 'gt')).listSync().whereType<File>().map((f) => _stemOf(f.path)).toSet();
      for (final s in ims.difference(gts)) {
        problems.add('$split: $s-এর মাস্ক নেই');
      }
      for (final s in gts.difference(ims)) {
        problems.add('$split: $s-এর ছবি নেই');
      }
      pairs += ims.intersection(gts).length;
    }
    if (problems.isEmpty) return 'সব ঠিক আছে: $pairs জোড়া ছবি-মাস্ক';
    return 'সমস্যা ${problems.length}টা: ${problems.take(5).join(', ')}';
  }
}

// ---------- আইসোলেটে চলা কাজ ----------

/// আসল ছবি খুলে ছোট কপি বানায়। ছবি ঘোরানো (EXIF) থাকলে সোজা করে নতুন JPG বানায়,
/// যাতে ছবি আর মাস্ক সব প্রোগ্রামে একই দিকে থাকে।
Map<String, dynamic> prepareImage(String path) {
  final original = File(path).readAsBytesSync();
  final decoded = img.decodeImage(original);
  if (decoded == null) {
    throw Exception('ছবি খোলা যায়নি। JPG বা PNG ছবি দিন');
  }
  final needsBake = (decoded.exif.imageIfd.orientation ?? 1) != 1;
  final im = img.bakeOrientation(decoded);
  final w = im.width;
  final h = im.height;
  final scale = kWorkSide / math.max(w, h);
  final small = scale < 1
      ? img.copyResize(im,
          width: (w * scale).round(),
          height: (h * scale).round(),
          interpolation: img.Interpolation.average)
      : im;
  final vscale = kViewSide / math.max(w, h);
  final view = vscale < 1
      ? img.copyResize(im,
          width: (w * vscale).round(),
          height: (h * vscale).round(),
          interpolation: img.Interpolation.average)
      : im;
  final lower = path.toLowerCase();
  final isPng = lower.endsWith('.png');
  final isJpg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
  final keep = !needsBake && (isPng || isJpg);
  return {
    'w': w,
    'h': h,
    'sw': small.width,
    'sh': small.height,
    'png': Uint8List.fromList(img.encodePng(small)),
    'view': Uint8List.fromList(img.encodeJpg(view, quality: 90)),
    'ext': keep ? (isPng ? 'png' : 'jpg') : 'jpg',
    'fixed': keep ? null : Uint8List.fromList(img.encodeJpg(im, quality: 95)),
  };
}

/// ছোট মাস্ক (0/255) থেকে আসল ছবির মাপের ৮-বিট grayscale PNG বানায়। মান শুধু 0 বা 255।
Uint8List fullMaskPng(Map<String, dynamic> a) {
  final sw = a['sw'] as int;
  final sh = a['sh'] as int;
  final w = a['w'] as int;
  final h = a['h'] as int;
  final m = a['mask'] as Uint8List;

  final x0s = Int32List(w);
  final x1s = Int32List(w);
  final xfs = Float32List(w);
  for (var x = 0; x < w; x++) {
    final fx = math.max(0.0, math.min(sw - 1.0, (x + 0.5) * sw / w - 0.5));
    final x0 = fx.floor();
    x0s[x] = x0;
    x1s[x] = math.min(x0 + 1, sw - 1);
    xfs[x] = fx - x0;
  }

  // প্রতি সারির শুরুতে ১ বাইট ফিল্টার (0 = কিছু না), তারপর পিক্সেল
  final raw = Uint8List((w + 1) * h);
  for (var y = 0; y < h; y++) {
    final fy = math.max(0.0, math.min(sh - 1.0, (y + 0.5) * sh / h - 0.5));
    final y0 = fy.floor();
    final y1 = math.min(y0 + 1, sh - 1);
    final wy = fy - y0;
    final r0 = y0 * sw;
    final r1 = y1 * sw;
    final o = y * (w + 1);
    for (var x = 0; x < w; x++) {
      final xa = x0s[x];
      final xb = x1s[x];
      final wx = xfs[x];
      final top = m[r0 + xa] + (m[r0 + xb] - m[r0 + xa]) * wx;
      final bottom = m[r1 + xa] + (m[r1 + xb] - m[r1 + xa]) * wx;
      final v = top + (bottom - top) * wy;
      raw[o + 1 + x] = v > 127.5 ? 255 : 0;
    }
  }
  return _encodeGrayPng(w, h, raw);
}

Uint8List _encodeGrayPng(int w, int h, Uint8List raw) {
  final out = BytesBuilder(copy: false);
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);

  void chunk(String type, Uint8List data) {
    final head = ByteData(4)..setUint32(0, data.length, Endian.big);
    out.add(head.buffer.asUint8List());
    final t = Uint8List.fromList(type.codeUnits);
    out.add(t);
    out.add(data);
    final tail = ByteData(4)..setUint32(0, _crc32(data, _crc32(t)), Endian.big);
    out.add(tail.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, w, Endian.big)
    ..setUint32(4, h, Endian.big)
    ..setUint8(8, 8) // প্রতি পিক্সেল ৮ বিট
    ..setUint8(9, 0) // 0 = grayscale (১ চ্যানেল)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', Uint8List.fromList(zlib.encode(raw)));
  chunk('IEND', Uint8List(0));
  return out.takeBytes();
}

/// পুরো ডেটাসেটকে এক বা একাধিক ZIP-এ ভরে। ছবি আগেই কম্প্রেসড, তাই ZIP-এ শুধু রাখা হয় (দ্রুত)।
/// ৩.৫ GB পার হলে নতুন অংশ শুরু হয়, তাই ডেটাসেট যত বড়ই হোক ZIP খুলতে সমস্যা হয় না।
List<String> makeZips(Map<String, dynamic> a) {
  final rootPath = a['root'] as String;
  final outDir = a['out'] as String;
  final out = Directory(outDir);
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync(recursive: true);

  final files = Directory(rootPath).listSync(recursive: true).whereType<File>().toList()
    ..sort((x, y) => x.path.compareTo(y.path));
  final prefix = rootPath.length + 1;
  final parts = <String>[];
  _ZipPart? part;

  for (final f in files) {
    final size = f.lengthSync();
    final cur = part;
    if (cur == null || cur.offset + size + 4096 > kZipPartBytes || cur.count >= 60000) {
      cur?.close();
      final path = '$outDir/$kRootName.part${parts.length + 1}.zip';
      parts.add(path);
      final np = _ZipPart(path);
      if (parts.length == 1) {
        for (final d in ['DIS-TR/im/', 'DIS-TR/gt/', 'DIS-VD/im/', 'DIS-VD/gt/']) {
          np.add('$kRootName/$d', Uint8List(0), DateTime.now());
        }
      }
      part = np;
    }
    part!.add('$kRootName/${f.path.substring(prefix)}', f.readAsBytesSync(), f.lastModifiedSync());
  }
  part?.close();

  if (parts.length == 1) {
    final single = '$outDir/$kRootName.zip';
    File(parts[0]).renameSync(single);
    return [single];
  }
  return parts;
}

class _Entry {
  _Entry(this.name, this.crc, this.size, this.time, this.date, this.offset);
  final Uint8List name;
  final int crc, size, time, date, offset;
}

/// ছোট একটা ZIP লেখক (কোনো কম্প্রেশন নেই, UTF-8 নাম)
class _ZipPart {
  _ZipPart(String path) : _raf = File(path).openSync(mode: FileMode.write);
  final RandomAccessFile _raf;
  final List<_Entry> _entries = [];
  int offset = 0;

  int get count => _entries.length;

  void add(String name, Uint8List data, DateTime mod) {
    final nameBytes = Uint8List.fromList(utf8.encode(name));
    final crc = _crc32(data);
    final time = _dosTime(mod);
    final date = _dosDate(mod);
    final h = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, time, Endian.little)
      ..setUint16(12, date, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    _raf.writeFromSync(h.buffer.asUint8List());
    _raf.writeFromSync(nameBytes);
    _raf.writeFromSync(data);
    _entries.add(_Entry(nameBytes, crc, data.length, time, date, offset));
    offset += 30 + nameBytes.length + data.length;
  }

  void close() {
    final cdStart = offset;
    var cdSize = 0;
    for (final e in _entries) {
      final c = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, 0, Endian.little)
        ..setUint16(12, e.time, Endian.little)
        ..setUint16(14, e.date, Endian.little)
        ..setUint32(16, e.crc, Endian.little)
        ..setUint32(20, e.size, Endian.little)
        ..setUint32(24, e.size, Endian.little)
        ..setUint16(28, e.name.length, Endian.little)
        ..setUint16(30, 0, Endian.little)
        ..setUint16(32, 0, Endian.little)
        ..setUint16(34, 0, Endian.little)
        ..setUint16(36, 0, Endian.little)
        ..setUint32(38, 0, Endian.little)
        ..setUint32(42, e.offset, Endian.little);
      _raf.writeFromSync(c.buffer.asUint8List());
      _raf.writeFromSync(e.name);
      cdSize += 46 + e.name.length;
    }
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(4, 0, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, _entries.length, Endian.little)
      ..setUint16(10, _entries.length, Endian.little)
      ..setUint32(12, cdSize, Endian.little)
      ..setUint32(16, cdStart, Endian.little)
      ..setUint16(20, 0, Endian.little);
    _raf.writeFromSync(end.buffer.asUint8List());
    _raf.closeSync();
  }
}

int _dosTime(DateTime d) => (d.hour << 11) | (d.minute << 5) | (d.second ~/ 2);

int _dosDate(DateTime d) =>
    (((d.year < 1980 ? 1980 : d.year) - 1980) << 9) | (d.month << 5) | d.day;

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

/// CRC32 (ZIP আর PNG দুটোতেই লাগে)। আগের মান দিলে সেখান থেকে চালিয়ে যায়।
int _crc32(List<int> data, [int crc = 0]) {
  var c = crc ^ 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
