import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/util/js_compat.dart' as js;

import 'fixtures.dart';
import 'pump_screen.dart';

void main() {
  setUpAll(setUpGoldens);

  test('every scene builds with typed state access', () {
    for (final n in kSceneNames) {
      final s = scene(n);
      expect(s.name, n);
      for (final c in s.state.chats) {
        final m = s.state.msgs(c.id);
        if (m != null && m.isNotEmpty) expect(m.first.chatId, c.id);
      }
    }
    expect(scene('chats-list').state.chats.first.unread, 1);
    expect(scene('chats-requests').state.contact(kDaveId)?.request, 'in');
    expect(scene('chats-empty').state.chats, isEmpty);
    expect(scene('onboarding-empty').state.needsOnboarding, isTrue);
  });

  testWidgets('pumpScreen sets size, padding, clock and fonts', (t) async {
    final s = scene('chat-group');
    late MediaQueryData mq;
    await pumpScreen(
      t,
      Builder(
        builder: (c) {
          mq = MediaQuery.of(c);
          return const Text('Hi');
        },
      ),
      theme: Brightness.light,
      scene: s,
    );
    expect(mq.size, const Size(412, 915));
    expect(mq.devicePixelRatio, 2);
    expect(mq.padding.top, 24);
    expect(mq.padding.bottom, 16);
    expect(mq.disableAnimations, isTrue);
    expect(js.now(), s.nowMs);
    expect(
      goldenName('chat', 'messages', Brightness.dark),
      'chat-messages-dark.png',
    );
  });
}
