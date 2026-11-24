import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Directory> _root() async {
  final base = await getApplicationCacheDirectory();
  return Directory('${base.path}/att');
}

Future<Directory> _dir() async {
  final d = await _root();
  if (!d.existsSync()) await d.create(recursive: true);
  return d;
}

Future<void> wipeMediaCache() async {
  try {
    final d = await _root();
    if (d.existsSync()) await d.delete(recursive: true);
  } catch (_) {}
}

String _random() {
  final r = Random.secure();
  return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

String extFor(String mime) => switch (mime.split(';').first.trim().toLowerCase()) {
  'video/mp4' => '.mp4',
  'video/webm' => '.webm',
  'video/quicktime' => '.mov',
  'video/3gpp' => '.3gp',
  'video/x-matroska' => '.mkv',
  'audio/mp4' || 'audio/aac' || 'audio/x-m4a' => '.m4a',
  'audio/webm' => '.webm',
  'audio/ogg' => '.ogg',
  'audio/mpeg' => '.mp3',
  'audio/wav' || 'audio/x-wav' => '.wav',
  _ => '',
};

Future<String> newMediaPath([String ext = '']) async => '${(await _dir()).path}/${_random()}$ext';

Future<String> writeMedia(Uint8List bytes, String mime) async {
  final path = await newMediaPath(extFor(mime));
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

Future<void> deleteMedia(String? path) async {
  if (path == null) return;
  try {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}
