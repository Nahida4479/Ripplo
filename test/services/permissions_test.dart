import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/services/permissions.dart';

import 'fake_mesh.dart';

void main() {
  test('allGranted needs bluetooth, wifi and notifications', () {
    expect(
      allGranted({
        'bluetooth': 'granted',
        'wifi': 'granted',
        'notifications': 'granted',
      }),
      true,
    );
    expect(
      allGranted({
        'bluetooth': 'granted',
        'wifi': 'granted',
        'notifications': 'prompt',
      }),
      false,
    );
    expect(allGranted({'bluetooth': 'granted', 'wifi': 'granted'}), false);
    expect(
      allGranted({
        'bluetooth': 'granted',
        'wifi': 'granted',
        'notifications': 'granted',
        'microphone': 'denied',
      }),
      true,
    );
  });

  test(
    'off device everything reads granted and the mesh is not asked',
    () async {
      final m = FakeMesh(isNative: false);
      final granted = {
        'bluetooth': 'granted',
        'wifi': 'granted',
        'notifications': 'granted',
        'microphone': 'granted',
      };
      expect(await checkPermissions(m), granted);
      expect(await requestPermissions(m), granted);
      expect(m.calls, isEmpty);
    },
  );

  test('native delegates to the mesh', () async {
    final m = FakeMesh()
      ..permissions = {'bluetooth': 'denied'}
      ..requested = {'bluetooth': 'granted'};
    expect(await checkPermissions(m), {'bluetooth': 'denied'});
    expect(await requestPermissions(m), {'bluetooth': 'granted'});
    expect(m.calls, ['check', 'request']);
  });
}
