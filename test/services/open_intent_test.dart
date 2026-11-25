import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/app_state.dart';
import 'package:ripplo/services/notification_open_intent.dart';

import 'sec_mesh.dart';

const chat = 'ABCDEFGHJKMNPQRS';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecMesh mesh;
  late RipploState state;
  late int clock;
  late List<String> opened;
  late int accepted;
  late OpenIntent intent;

  setUp(() {
    mesh = SecMesh();
    state = RipploState();
    clock = 1000;
    opened = [];
    accepted = 0;
    intent = OpenIntent(
      mesh: mesh,
      state: state,
      acceptCall: () async => accepted++,
      openChat: opened.add,
      now: () => clock,
    );
  });

  tearDown(() => intent.dispose());

  void ring({String peer = chat, String id = 'c1'}) {
    state.call = {'peer': peer, 'dir': 'in', 'status': 'ringing', 'id': id};
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  test('chat open navigates only for valid ids', () async {
    mesh.open = {'chatId': chat};
    await intent.take();
    mesh.open = {'chatId': 'a/../b'};
    await intent.take();
    expect(opened, [chat]);
  });

  test('answer token accepts matching ringing call', () async {
    intent.start();
    mesh.open = {'chatId': chat, 'answer': 'c1'};
    await intent.take();
    ring();
    await settle();
    expect(accepted, 1);
  });

  test('no answer token never auto-accepts', () async {
    intent.start();
    await settle();
    mesh.open = {'chatId': chat};
    await intent.take();
    ring();
    await settle();
    expect(accepted, 0);
  });

  test('wrong call id or peer is not accepted', () async {
    intent.start();
    mesh.open = {'chatId': chat, 'answer': 'c1'};
    await intent.take();
    ring(id: 'other');
    await settle();
    ring(peer: 'ZZZZZZ');
    await settle();
    expect(accepted, 0);
  });

  test('expired answer window is not accepted', () async {
    intent.start();
    mesh.open = {'chatId': chat, 'answer': 'c1'};
    await intent.take();
    clock += 21000;
    ring();
    await settle();
    expect(accepted, 0);
  });

  test('answer is single use', () async {
    intent.start();
    mesh.open = {'chatId': chat, 'answer': 'c1'};
    await intent.take();
    ring();
    await settle();
    state.call = null;
    await settle();
    ring();
    await settle();
    expect(accepted, 1);
  });

  test('locked device enters lockedCall and ends it after call', () async {
    mesh.locked = true;
    intent.start();
    mesh.open = {'chatId': chat, 'answer': 'c1'};
    await intent.take();
    expect(state.lockedCall, isTrue);
    ring();
    await settle();
    state.call = null;
    await settle();
    expect(state.lockedCall, isFalse);
    expect(mesh.calls, contains('endLockedCall'));
  });

  test('unlocked device does not enter lockedCall', () async {
    intent.start();
    mesh.open = {'chatId': chat, 'answer': 'c1'};
    await intent.take();
    expect(state.lockedCall, isFalse);
  });
}
