import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../tool/parity.dart';

img.Image solid(int w, int h, int r) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, 0, 0));
  return im;
}

void main() {
  test('diffImages counts pixels over the channel threshold', () {
    final a = solid(10, 10, 100);
    final b = solid(10, 10, 100);
    for (var x = 0; x < 10; x++) {
      b.setPixelRgb(x, 0, 130, 0, 0);
      b.setPixelRgb(x, 1, 110, 0, 0);
    }
    final d = diffImages(a, b);
    expect(d.percent, closeTo(10, 1e-9));
    expect(diffImages(a, a).percent, 0);
  });

  test('run exits non-zero over 1.5 percent or on a missing reference', () {
    final dir = Directory.systemTemp.createTempSync('parity');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final d in ['g', 'r']) {
      Directory('${dir.path}/$d').createSync();
    }
    File(
      '${dir.path}/g/a.png',
    ).writeAsBytesSync(img.encodePng(solid(20, 20, 0)));
    File(
      '${dir.path}/r/a.png',
    ).writeAsBytesSync(img.encodePng(solid(20, 20, 0)));
    int go() => run('${dir.path}/g', '${dir.path}/r', '${dir.path}/o');
    expect(go(), 0);
    final off = solid(20, 20, 0);
    for (var x = 0; x < 20; x++) {
      off.setPixelRgb(x, 0, 255, 0, 0);
    }
    File('${dir.path}/g/a.png').writeAsBytesSync(img.encodePng(off));
    expect(go(), 1);
    expect(File('${dir.path}/o/a.png').existsSync(), isTrue);
    File(
      '${dir.path}/g/a.png',
    ).writeAsBytesSync(img.encodePng(solid(20, 20, 0)));
    File(
      '${dir.path}/g/b.png',
    ).writeAsBytesSync(img.encodePng(solid(20, 20, 0)));
    expect(go(), 1);
  });
}
