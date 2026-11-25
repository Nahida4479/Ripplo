import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/ui/views/chat_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

const List<String> kChatScenes = [
  'chat-empty',
  'chat-messages',
  'chat-messages-accent',
  'chat-typing',
  'chat-composer',
  'chat-reply',
  'chat-staged',
  'chat-staged-two',
  'chat-unverified',
  'chat-group',
];

const Map<String, double> scrollOffsets = {
  'chat-reply': 53.25,
  'chat-staged-two': 53.25,
};

Future<void> pumpChat(
  WidgetTester tester,
  String name,
  Brightness theme,
) async {
  final sc = scene(name);
  for (final id in sc.state.messages.keys) {
    for (final m in sc.state.msgs(id)!) {
      final aid = m.att?.attId;
      if (aid != null && sc.blobs.containsKey(aid)) {
        m.att!.bytes = sc.blobs[aid];
      }
    }
  }
  if (name == 'chat-typing') sc.state.typing[sc.id!] = [sc.id!];
  final replyText = sc.extras['replyText'] as String?;
  final staged = (sc.extras['staged'] as List?) ?? const [];
  final key = GlobalKey<ChatViewState>();
  await pumpScreen(
    tester,
    ChatView(
      key: key,
      id: sc.id!,
      state: sc.state,
      live: false,
      initialText: (sc.extras['text'] as String?) ?? '',
      typingFreeze: Duration.zero,
    ),
    theme: theme,
    scene: sc,
  );
  final ctx = tester.element(find.byType(ChatView));
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, ctx);
    }
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  if (replyText != null) {
    key.currentState!.replyToMessage(
      sc.state.msgs(sc.id!)!.firstWhere((m) => m.text == replyText),
    );
  }
  if (staged.isNotEmpty) {
    key.currentState!.stageMedia([
      for (final s in staged)
        StagedMedia(
          bytes: fixturePng((s as List)[0] as int, s[1] as int),
          kind: 'image',
          type: 'image/png',
        ),
    ]);
  }
  await tester.pump();
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, ctx);
    }
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final offset = scrollOffsets[name];
  if (offset != null) {
    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Scrollable),
    );
    tester.state<ScrollableState>(scrollable.first).position.jumpTo(offset);
    await tester.pump();
  }
}

void main() {
  setUpAll(setUpGoldens);
  for (final name in kChatScenes) {
    for (final theme in [Brightness.dark, Brightness.light]) {
      testWidgets('$name ${theme.name}', (tester) async {
        await pumpChat(tester, name, theme);
        await expectGolden(tester, 'chat', scene(name).variant, theme);
      });
    }
  }
}
