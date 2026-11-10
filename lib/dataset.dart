// dataset.dart
// ১) ব্যাকগ্রাউন্ড-রিমুভ AI-র ডেটাসেট (DIS5K ফরম্যাট):
//      DIS5K/DIS-TR/im/<নাম>.jpg   DIS5K/DIS-TR/gt/<নাম>.png
//      DIS5K/DIS-VD/im/<নাম>.jpg   DIS5K/DIS-VD/gt/<নাম>.png      (প্রতি ১০টার ১টা VD)
//    ছবি আর মাস্কের নাম হুবহু এক, তাই ID কখনো আলাদা হয় না।
// ২) "সবুজ দাগ AI"-কে শেখানোর ছোট ডেটা (আলাদা ফোল্ডার, আলাদা ZIP):
//      AI_marks/im/<নাম>.jpg       ছোট ছবি
//      AI_marks/gt/<নাম>.png       আপনার দেওয়া সবুজ দাগ
//      AI_marks/subject/<নাম>.png  চূড়ান্ত মাস্ক (AI ঠিক জায়গায় দাগ দিল কিনা মাপার জন্য)
//    এটা সেভ হয় শুধু তখন, যখন আপনি নিজে অন্তত একটা সবুজ দাগ দিয়েছেন।

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> zipInBackground(String rootPath, String zipPath) =>
    Isolate.run(() {
      final enc = ZipFileEncoder();
      enc.zipDirectory(Directory(rootPath), filename: zipPath, level: 1);
    });

class Dataset {
  Dataset._(this.base, this.root, this.marksRoot, this._metaFile, this._meta);

  final Directory base;
  final Directory root; // .../DIS5K
  final Directory marksRoot; // .../AI_marks
  final File _metaFile;
  final Map<String, dynamic> _meta;
  Future<void> _chain = Future<void>.value();

  static Future<Dataset> open() async {
    final base = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(base.path, 'DIS5K'));
    await root.create(recursive: true);
    final marksRoot = Directory(p.join(base.path, 'AI_marks'));
    final metaFile = File(p.join(base.path, 'mask_meta.json'));
    Map<String, dynamic> meta = {'saved': <String, dynamic>{}};
    if (await metaFile.exists()) {
      try {
        final m = jsonDecode(await metaFile.readAsString());
        if (m is Map<String, dynamic> && m['saved'] is Map) meta = m;
      } catch (_) {}
    }
    return Dataset._(base, root, marksRoot, metaFile, meta);
  }

  Map<String, dynamic> get _saved => _meta['saved'] as Map<String, dynamic>;

  int get count => _saved.length;
  int get markCount => _saved.values.where((v) => (v as Map)['mark'] == true).length;
  int countSplit(String split) =>
      _saved.values.where((v) => (v as Map)['split'] == split).length;

  /// AI ফাইলের জায়গা (অ্যাপের ভেতরে)
  File get modelFile => File(p.join(base.path, 'marker_model.bin'));

  /// এই ছবি আগেই সেভ হয়েছে কিনা (নাম + সাইজ দিয়ে চেনা)
  bool isDone(String name, int size) => _saved.containsKey('$name|$size');

  Future<void> save({
    required String name,
    required int size,
    required Uint8List jpg,
    required Uint8List png,
    Uint8List? markJpg,
    Uint8List? markPng,
    Uint8List? subjectPng,
  }) {
    final f = _chain.then((_) => _saveImpl(name, size, jpg, png, markJpg, markPng, subjectPng));
    _chain = f.catchError((_) {});
    return f;
  }

  String _clean(String name) {
    final stem = p.basenameWithoutExtension(name);
    final c = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return c.isEmpty ? 'img' : c;
  }

  Future<void> _saveImpl(String name, int size, Uint8List jpg, Uint8List png,
      Uint8List? markJpg, Uint8List? markPng, Uint8List? subjectPng) async {
    final key = '$name|$size';
    var entry = _saved[key] as Map<String, dynamic>?;
    if (entry == null) {
      final used = _saved.values.map((v) => (v as Map)['stem']).toSet();
      var stem = _clean(name);
      if (used.contains(stem)) stem = '${stem}_${_saved.length + 1}';
      final split = (_saved.length % 10 == 9) ? 'VD' : 'TR';
      entry = <String, dynamic>{'stem': stem, 'split': split};
    }
    final stem = entry['stem'] as String;
    final dir = 'DIS-${entry['split']}';
    final imDir = Directory(p.join(root.path, dir, 'im'));
    final gtDir = Directory(p.join(root.path, dir, 'gt'));
    await imDir.create(recursive: true);
    await gtDir.create(recursive: true);
    await File(p.join(imDir.path, '$stem.jpg')).writeAsBytes(jpg, flush: true);
    await File(p.join(gtDir.path, '$stem.png')).writeAsBytes(png, flush: true);

    if (markJpg != null && markPng != null && subjectPng != null) {
      for (final d in ['im', 'gt', 'subject']) {
        await Directory(p.join(marksRoot.path, d)).create(recursive: true);
      }
      await File(p.join(marksRoot.path, 'im', '$stem.jpg')).writeAsBytes(markJpg, flush: true);
      await File(p.join(marksRoot.path, 'gt', '$stem.png')).writeAsBytes(markPng, flush: true);
      await File(p.join(marksRoot.path, 'subject', '$stem.png')).writeAsBytes(subjectPng, flush: true);
      entry['mark'] = true;
    }

    _saved[key] = entry;
    final tmp = File('${_metaFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(_meta), flush: true);
    await tmp.rename(_metaFile.path);
  }

  /// ZIP বানায়। ফেরত: [ডেটাসেট ZIP] এবং (থাকলে) [AI_marks ZIP]
  Future<List<String>> exportZips() async {
    await _chain;
    final out = <String>[];
    final z1 = p.join(base.path, 'DIS5K_dataset.zip');
    if (await File(z1).exists()) await File(z1).delete();
    await zipInBackground(root.path, z1);
    out.add(z1);
    if (markCount > 0 && await marksRoot.exists()) {
      final z2 = p.join(base.path, 'AI_marks.zip');
      if (await File(z2).exists()) await File(z2).delete();
      await zipInBackground(marksRoot.path, z2);
      out.add(z2);
    }
    return out;
  }
}
