import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Photo bytes on disk. Same approach as the signature PNGs: files under the
// app's documents folder, or an inline data: URI on web where the browser
// can't write files.
class MediaFiles {
  const MediaFiles();

  Future<String> save(String fileName, Uint8List bytes, String mimeType) async {
    if (kIsWeb) return 'data:$mimeType;base64,${base64Encode(bytes)}';
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'dc_media'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List?> read(String path) async {
    if (path.startsWith('data:')) return base64Decode(path.substring(path.indexOf(',') + 1));
    if (kIsWeb) return null;
    final file = File(path);
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> delete(String path) async {
    if (kIsWeb || path.startsWith('data:')) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A leftover file is harmless; never fail a sync or delete over it.
    }
  }
}
