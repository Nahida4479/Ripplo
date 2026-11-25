import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/services/backup.dart';
import 'package:ripplo/util/js.dart' as js;

import 'fake_mesh.dart';

void main() {
  final savedClock = js.now;
  tearDownAll(() => js.now = savedClock);

  test('groupCode keeps digits, groups by five and caps at thirty', () {
    expect(groupCode('1234567890'), '12345 67890');
    expect(groupCode('ab12-34 56x'), '12345 6');
    expect(groupCode(''), '');
    expect(groupCode('1' * 40), '11111 11111 11111 11111 11111 11111');
  });

  test('backupMeta carries app version, clock and ripploId', () {
    js.now = () => 42;
    final s = RipploState()
      ..profile = {'tag': 't', 'ripploId': 'rid', 'name': 'n'};
    expect(backupMeta(s, '1.0'), {
      'app': '1.0',
      'created': 42,
      'ripploId': 'rid',
    });
    expect(backupMeta(RipploState(), '1.0'), {'app': '1.0', 'created': 42});
  });

  test(
    'autoBackup creates an auto backup only when enabled with a folder',
    () async {
      final m = FakeMesh()
        ..backupStatusResult = {'enabled': true, 'folder': 'f'};
      await autoBackup(m, RipploState(), '1.0');
      expect(m.created.length, 1);
      expect(m.created.single.$1, 'auto');

      m.backupStatusResult = {'enabled': true, 'folder': ''};
      await autoBackup(m, RipploState(), '1.0');
      m.backupStatusResult = {'enabled': false, 'folder': 'f'};
      await autoBackup(m, RipploState(), '1.0');
      expect(m.created.length, 1);
    },
  );

  test('autoBackup does nothing off device and swallows failures', () async {
    final off = FakeMesh(isNative: false);
    await autoBackup(off, RipploState(), '1.0');
    expect(off.calls, isEmpty);

    final broken = FakeMesh()..backupStatusError = StateError('io');
    await autoBackup(broken, RipploState(), '1.0');
    expect(broken.created, isEmpty);
  });
}
