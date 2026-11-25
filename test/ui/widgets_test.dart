import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/services/theme.dart';
import 'package:ripplo/ui/widgets.dart';

Widget host(Widget child, {bool light = false}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildTheme(RipploColors.resolve(light: light)),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(412, 915),
      padding: EdgeInsets.only(top: 24, bottom: 16),
    ),
    child: child,
  ),
);

Size sizeOf(WidgetTester t, Finder f) => t.getSize(f);

void main() {
  testWidgets('page with every widget lays out', (t) async {
    var on = false;
    await t.pumpWidget(
      host(
        Stack(
          children: [
            RPage(
              children: [
                RHdr(
                  children: [
                    const RHdrTitle('Chats', sub: 'sub'),
                    RIconBtn(
                      icon: LucideIcons.refreshCw,
                      spin: true,
                      onTap: () {},
                    ),
                  ],
                ),
                const RField(search: true, hint: 'Search'),
                const RSection('Profile'),
                RCard(
                  children: [
                    RRow(
                      children: const [
                        Expanded(child: RLabel('A')),
                        RVal('b'),
                      ],
                    ),
                    RRow(
                      onTap: () {},
                      children: [
                        const Expanded(child: RLabel('B')),
                        const RChip('ok', kind: RChipKind.ok),
                        RSwitch(value: on, onChanged: (v) => on = v),
                      ],
                    ),
                    const RDevWarnRow('warn'),
                  ],
                ),
                const RSection('Next'),
                RCard(
                  pad: true,
                  children: [
                    RSeg<int>(
                      options: const [(0, 'a'), (1, 'b')],
                      value: 1,
                      onChanged: (_) {},
                    ),
                    RSwatches(
                      children: [
                        const RSwatch(kind: RSwatchKind.rainbow),
                        const RSwatch(kind: RSwatchKind.none, selected: true),
                        RSwatch(color: const Color(0xFF22C55E)),
                      ],
                    ),
                  ],
                ),
                RListRow(
                  children: [
                    const Avatar(name: 'Anna', size: 48),
                    const Expanded(child: RListName('Anna')),
                    RListMeta(children: const [Text('10:30'), RBadge('3')]),
                  ],
                ),
                RInline(
                  child: RBtn(text: 'Go', onTap: () {}),
                ),
                const RBtn(text: 'Off', kind: RBtnKind.ghost),
                const RTypingDots(freeze: Duration(milliseconds: 300)),
                const REmpty('empty'),
              ],
            ),
            RTabBar(
              items: const [
                RTabItem(
                  path: '/',
                  icon: LucideIcons.messageCircle,
                  label: 'Chats',
                ),
                RTabItem(
                  path: '/people',
                  icon: LucideIcons.users,
                  label: 'People',
                ),
                RTabItem(
                  path: '/settings',
                  icon: LucideIcons.settings,
                  label: 'Settings',
                  alert: true,
                ),
              ],
              current: '/',
              onSelect: (_) {},
            ),
            RToast(text: 'Hello'),
            RSheet(
              onDismiss: () {},
              children: [
                const RSheetTitle('Title'),
                const RSheetText('Body'),
                RSheetActions(
                  children: [
                    RBtn(text: 'Cancel', kind: RBtnKind.ghost, onTap: () {}),
                    RBtn(text: 'OK', kind: RBtnKind.danger, onTap: () {}),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
    expect(t.takeException(), isNull);
    expect(sizeOf(t, find.byType(RSwitch)), const Size(48, 28));
    expect(sizeOf(t, find.byType(RSeg<int>)).height, 40);
    expect(sizeOf(t, find.byType(RIconBtn)), const Size(40, 40));
    expect(sizeOf(t, find.byType(RField)).height, 48);
    expect(sizeOf(t, find.byType(RListRow)).height, 68);
    expect(sizeOf(t, find.widgetWithText(RBtn, 'Go')).height, 44);
    expect(sizeOf(t, find.byType(RHdr)).height, closeTo(56, .01));
    expect(sizeOf(t, find.widgetWithText(RRow, 'A')).height, 52);
    expect(sizeOf(t, find.widgetWithText(RRow, 'B')).height, 52);
    expect(sizeOf(t, find.byType(RBadge)).height, 20);
    expect(t.getBottomLeft(find.byType(RTabBar)).dy, closeTo(600 - 28, 0.01));
  });
}
