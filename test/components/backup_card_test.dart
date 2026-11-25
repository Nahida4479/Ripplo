import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/ui/components/backup_card.dart';
import 'package:ripplo/i18n.dart';
import 'package:ripplo/mesh/bridge.dart' as bridge;
import 'package:ripplo/ui/theme.dart';
import 'package:ripplo/ui/tokens.dart';
import 'package:ripplo/ui/ui_state.dart';

class NativeMesh implements bridge.Mesh {
  Map<String, Object?> status = {'enabled': false, 'lastAt': 0, 'folder': null};
  int created = 0;

  @override
  bool get isNative => true;

  @override
  Future<Map<String, Object?>> backupStatus() async => status;

  @override
  Future<String> backupEnable() async {
    status = {'enabled': true, 'lastAt': 0, 'folder': null};
    return '1111122222333334444455555';
  }

  @override
  Future<String> backupChooseFolder() async => 'Docs';

  @override
  Future<bool> authenticate(String reason) async => true;

  @override
  Future<Map<String, Object?>> backupCreate(
    String mode,
    Map<String, Object?> meta,
  ) async {
    created++;
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('enable shows code, verifies last group, then folder step', (
    tester,
  ) async {
    final mesh = NativeMesh();
    final colors = RipploColors.resolve(
      light: false,
      accent: hexColor('#4f9cf9'),
      gradient: null,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(colors),
        home: Material(
          child: SingleChildScrollView(child: BackupCard(mesh: mesh)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(t('backupEnable')));
    await tester.pump();
    await tester.pump();
    expect(find.text('11111'), findsOneWidget);
    expect(find.text('55555'), findsOneWidget);
    await tester.tap(find.text(t('codeWritten')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '12345');
    await tester.pump();
    await tester.tap(find.text(t('continue')));
    await tester.pump();
    expect(ui.toastText, t('codeMismatch'));
    await tester.enterText(find.byType(TextField), '55555');
    await tester.pump();
    await tester.tap(find.text(t('continue')));
    await tester.pump();
    expect(find.text(t('folderTitle')), findsOneWidget);
    await tester.tap(find.text(t('chooseFolder')));
    await tester.pump();
    await tester.pump();
    expect(find.text(t('backupNow')), findsOneWidget);
    await tester.tap(find.text(t('backupNow')));
    await tester.pump();
    await tester.pump();
    expect(mesh.created, 1);
    ui.reset();
  });
}
