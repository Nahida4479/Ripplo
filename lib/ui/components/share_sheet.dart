import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/api.dart' as api;
import '../../core/state.dart';
import '../../crypto/identity.dart' show RipploError;
import '../../i18n.dart';
import '../ui_state.dart';
import '../widgets.dart';

class ShareSheet extends StatelessWidget {
  const ShareSheet({super.key, this.state, this.onOpenChat});

  final RipploState? state;
  final ValueChanged<String>? onOpenChat;

  RipploState get _state => state ?? api.state;

  void _close() => ui.share = null;

  Future<void> _pick(Chat c) async {
    final s = ui.share;
    if (s == null) return;
    try {
      if (s.kind == 'text') {
        final text = s.text ?? '';
        if (text.length > api.maxText) {
          toast(t('shareTooLong'));
          return;
        }
        await api.sendText(c.id, text);
      } else {
        final bytes = await File(s.path!).readAsBytes();
        await api.sendAttachment(c.id, (
          bytes: bytes,
          type: s.mime ?? '',
          duration: null,
        ), s.kind);
      }
      _close();
      onOpenChat?.call(c.id);
    } catch (e) {
      toast(
        e is RipploError && e.code == 'media_locked'
            ? t('err_media_locked')
            : e is RipploError
            ? e.message
            : t('playFailed'),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, ui, locale]),
    builder: (context, _) {
      final s = ui.share;
      if (s == null) return const SizedBox.shrink();
      final chats = [
        for (final c in _state.chats)
          if (c.type == 'group' || _state.contact(c.id)?.request == null) c,
      ];
      final preview = s.kind == 'text'
          ? (s.text ?? '').substring(
              0,
              (s.text ?? '').length < 120 ? (s.text ?? '').length : 120,
            )
          : t(
              s.kind == 'video'
                  ? 'videoMessage'
                  : s.kind == 'voice'
                  ? 'voiceMessage'
                  : 'photoMessage',
            );
      final mq = MediaQuery.of(context);
      return RSheet(
        onDismiss: _close,
        label: t('shareTo'),
        children: [
          RSheetTitle(t('shareTo')),
          if (s.kind == 'image' && s.path != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(s.path!),
                    height: 120,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              preview,
              style: rs(
                context,
                RipploText.rowHint,
                context.rc.text2,
              ).copyWith(height: 18.2 / 13),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: mq.size.height * .5),
            child: SingleChildScrollView(
              child: RCard(
                marginBottom: 0,
                children: [
                  if (chats.isEmpty) REmpty(t('noContacts')),
                  for (final c in chats)
                    RListRow(
                      onTap: () => _pick(c),
                      children: [
                        Avatar(
                          name: c.name,
                          photo: _state.contact(c.id)?.avatar,
                          group: c.type == 'group',
                          size: 40,
                        ),
                        Expanded(child: RListName(c.name)),
                      ],
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 28),
            child: RBtn(
              text: t('cancel'),
              kind: RBtnKind.ghost,
              block: true,
              onTap: _close,
            ),
          ),
        ],
      );
    },
  );
}
