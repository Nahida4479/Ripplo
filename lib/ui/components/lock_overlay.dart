import 'package:material_ui/material_ui.dart';

import '../../i18n.dart';
import '../widgets.dart';
import 'brand.dart';

class LockOverlay extends StatelessWidget {
  const LockOverlay({super.key, this.onUnlock, this.busy = false});

  final VoidCallback? onUnlock;
  final bool busy;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: locale,
    builder: (context, _) {
      final c = context.rc;
      return Semantics(
        container: true,
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: t('locked'),
        child: ScrollCenter(
          children: [
            const AppIcon(),
            Nudge(-1, child: Text('Ripplo', style: brandH1(context))),
            Nudge(
              -1,
              child: Text(
                t('locked'),
                style: rs(context, RipploText.body, c.text2),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 200),
              child: IntrinsicWidth(
                child: RBtn(
                  icon: LucideIcons.lock,
                  iconStroke: 1.75,
                  text: t('unlock'),
                  onTap: busy ? null : onUnlock,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
