import 'package:material_ui/material_ui.dart';

import '../core/api.dart' as api;
import '../core/state.dart';
import '../crypto/identity.dart' show RipploError;
import '../i18n.dart';
import '../ui/ui_state.dart';
import '../ui/widgets.dart';

class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key, this.state, this.onOpenChat});

  final RipploState? state;
  final ValueChanged<String>? onOpenChat;

  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  final _name = TextEditingController();
  final _picked = <String>[];

  RipploState get _state => widget.state ?? api.state;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _close() {
    ui.newChat = null;
    _name.clear();
    setState(_picked.clear);
  }

  void _pick(Contact c) {
    if (ui.newChat != 'group') {
      _close();
      widget.onOpenChat?.call(c.id);
      return;
    }
    setState(
      () => _picked.contains(c.id) ? _picked.remove(c.id) : _picked.add(c.id),
    );
  }

  Future<void> _create() async {
    try {
      final chat = await api.createGroup(_name.text.trim(), List.of(_picked));
      _close();
      widget.onOpenChat?.call(chat.id);
    } catch (e) {
      toast(e is RipploError ? e.message : e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, ui, locale, _name]),
    builder: (context, _) {
      if (ui.newChat == null) return const SizedBox.shrink();
      final group = ui.newChat == 'group';
      final contacts = [
        for (final id in _state.contacts.keys)
          if (_state.contact(id) case final c? when c.request == null) c,
      ]..sort((a, b) => a.name.compareTo(b.name));
      final c = context.rc;
      return RSheet(
        onDismiss: _close,
        label: group ? t('newGroup') : t('newChat'),
        children: [
          RSheetTitle(group ? t('newGroup') : t('newChat')),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: RSeg<String>(
              options: [('chat', t('newChat')), ('group', t('newGroup'))],
              value: group ? 'group' : 'chat',
              onChanged: (v) => ui.newChat = v,
            ),
          ),
          if (group)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: RField(
                controller: _name,
                maxLength: 40,
                hint: t('groupName'),
                label: t('groupName'),
              ),
            ),
          if (contacts.isEmpty) REmpty(t('noContacts')),
          for (final k in contacts)
            RListRow(
              onTap: () => _pick(k),
              children: [
                Avatar(
                  name: k.name,
                  photo: k.avatar,
                  size: 40,
                  shield: k.verification == 'none',
                ),
                Expanded(child: RListName(k.name)),
                if (_picked.contains(k.id))
                  Lucide(LucideIcons.check, size: 22, color: c.accent),
              ],
            ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: RSheetActions(
              children: [
                RBtn(text: t('cancel'), kind: RBtnKind.ghost, onTap: _close),
                if (group)
                  RBtn(
                    text: t('create'),
                    onTap: _name.text.trim().isEmpty || _picked.isEmpty
                        ? null
                        : _create,
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
