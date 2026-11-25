import 'package:material_ui/material_ui.dart';

import '../i18n.dart';
import '../ui/ui_state.dart';
import '../ui/widgets.dart';

class ConfirmSheet extends StatelessWidget {
  const ConfirmSheet({super.key});

  void _close() => ui.confirm = null;

  Future<void> _ok(ConfirmRequest c) async {
    _close();
    await c.onOk();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([ui, locale]),
    builder: (context, _) {
      final c = ui.confirm;
      if (c == null) return const SizedBox.shrink();
      return RSheet(
        onDismiss: _close,
        label: c.title,
        children: [
          RSheetTitle(c.title),
          RSheetText(c.text),
          RSheetActions(
            children: [
              RBtn(
                text: c.cancel ?? t('cancel'),
                kind: RBtnKind.ghost,
                onTap: _close,
              ),
              RBtn(
                text: c.ok,
                kind: c.danger ? RBtnKind.danger : RBtnKind.primary,
                onTap: () => _ok(c),
              ),
            ],
          ),
        ],
      );
    },
  );
}
