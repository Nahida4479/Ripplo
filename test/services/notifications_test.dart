import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/services/notifications.dart';

import 'fake_mesh.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('skips the notice of the chat that is open while visible', () async {
    final m = FakeMesh(isNative: false);
    final n = Notifications(mesh: m, visible: () => true)..setOpenChat('a');
    n.notify((title: 'T', body: 'B', chatId: 'a'));
    await settle();
    expect(m.notified, isEmpty);
    n.notify((title: 'T', body: 'B', chatId: 'b'));
    await settle();
    expect(m.notified.map((x) => x.chatId), ['b']);
  });

  test('shows the open chat notice when the app is hidden', () async {
    final m = FakeMesh(isNative: false);
    final n = Notifications(mesh: m, visible: () => false)..setOpenChat('a');
    n.notify((title: 'T', body: 'B', chatId: 'a'));
    await settle();
    expect(m.notified.length, 1);
  });

  test('a null chat matches a null open chat, as in the JS rule', () async {
    final m = FakeMesh(isNative: false);
    final n = Notifications(mesh: m, visible: () => true);
    n.notify((title: 'T', body: 'B', chatId: null));
    await settle();
    expect(m.notified, isEmpty);
    n.setOpenChat('a');
    n.notify((title: 'T', body: 'B', chatId: null));
    await settle();
    expect(m.notified.length, 1);
  });

  test('native asks for permission once and drops notices when denied', () async {
    final m = FakeMesh()
      ..permissions = {'notifications': 'denied'}
      ..requested = {'notifications': 'denied'};
    final n = Notifications(mesh: m, visible: () => false);
    n.notify((title: 'T', body: 'B', chatId: 'a'));
    n.notify((title: 'T', body: 'B', chatId: 'a'));
    await settle();
    expect(m.notified, isEmpty);
    expect(m.calls, ['check', 'request']);
  });

  test('native delivers when permission is already granted', () async {
    final m = FakeMesh()..permissions = {'notifications': 'granted'};
    final n = Notifications(mesh: m, visible: () => false);
    n.notify((title: 'T', body: 'B', chatId: 'a'));
    await settle();
    expect(m.notified.length, 1);
    expect(m.calls, ['check', 'notify']);
  });

  test('takeTap passes the chat of a pending open to the tap callback', () async {
    final m = FakeMesh();
    final taps = <String>[];
    final n = Notifications(mesh: m)..onTap = taps.add;
    await n.takeTap();
    expect(taps, isEmpty);
    m.takeOpenResult = {'chatId': 'c'};
    await n.takeTap();
    expect(taps, ['c']);
  });
}
