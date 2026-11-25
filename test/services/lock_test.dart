import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/services/lock.dart';

import 'sec_mesh.dart';

void main() {
  late SecMesh mesh;
  late RipploState state;
  late int clock;
  late List<Map<String, Object?>> saved;
  late AppLock lock;

  setUp(() {
    mesh = SecMesh();
    state = RipploState();
    clock = 1000;
    saved = [];
    lock = AppLock(
      mesh: mesh,
      state: state,
      saveSettings: (p) async => saved.add(p),
      now: () => clock,
    );
  });

  test('unlock success clears lock', () async {
    state.settings.appLock = true;
    lock.back();
    lock.away();
    clock += 31000;
    lock.back();
    await Future<void>.delayed(Duration.zero);
    expect(lock.locked, isFalse);
    expect(mesh.calls, ['auth']);
  });

  test('failed authenticate keeps locked', () async {
    mesh.authResult = false;
    state.settings.appLock = true;
    lock.away();
    clock += 31000;
    lock.back();
    await Future<void>.delayed(Duration.zero);
    expect(lock.locked, isTrue);
    expect(lock.busy, isFalse);
  });

  test('short absence does not lock', () async {
    state.settings.appLock = true;
    lock.away();
    clock += 5000;
    lock.back();
    await Future<void>.delayed(Duration.zero);
    expect(lock.locked, isFalse);
    expect(mesh.calls, isEmpty);
  });

  test('no lock when appLock off', () async {
    lock.away();
    clock += 60000;
    lock.back();
    await Future<void>.delayed(Duration.zero);
    expect(lock.locked, isFalse);
  });

  test('lockedCall gating shows only call content', () async {
    state.settings.appLock = true;
    mesh.authResult = false;
    lock.away();
    clock += 31000;
    lock.back();
    await Future<void>.delayed(Duration.zero);
    expect(lock.locked, isTrue);
    expect(lock.showLock, isTrue);
    expect(lock.showContent, isTrue);
    state.lockedCall = true;
    expect(lock.showLock, isFalse);
    expect(lock.showContent, isFalse);
    state.lockedCall = false;
    expect(lock.showLock, isTrue);
  });

  test('setAppLock requires authentication', () async {
    mesh.authResult = false;
    expect(await lock.setAppLock(true), isFalse);
    expect(saved, isEmpty);
    expect(mesh.secure, isEmpty);
    mesh.authResult = true;
    expect(await lock.setAppLock(true), isTrue);
    expect(saved, [
      {'appLock': true},
    ]);
    expect(mesh.secure, [true]);
  });
}
