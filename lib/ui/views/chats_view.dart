import 'package:material_ui/material_ui.dart';

import '../../core/api.dart' as api;
import '../../core/state.dart';
import '../../i18n.dart';
import '../ui_state.dart';
import '../widgets.dart';
import '../../util/js.dart' as js;

String formatChatTime(int ts) {
  if (ts == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final n = DateTime.fromMillisecondsSinceEpoch(js.now());
  final pl = locale.value == 'pl';
  String two(int v) => v.toString().padLeft(2, '0');
  if (d.year == n.year && d.month == n.month && d.day == n.day) {
    if (pl) return '${two(d.hour)}:${two(d.minute)}';
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${two(h)}:${two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
  }
  const en = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  const plm = [
    'sty',
    'lut',
    'mar',
    'kwi',
    'maj',
    'cze',
    'lip',
    'sie',
    'wrz',
    'paź',
    'lis',
    'gru',
  ];
  return pl ? '${d.day} ${plm[d.month - 1]}' : '${en[d.month - 1]} ${d.day}';
}

class ChatsView extends StatefulWidget {
  const ChatsView({
    super.key,
    this.state,
    this.onOpenSettings,
    this.onOpenChat,
    this.onAddContact,
    this.onNewChat,
  });

  final RipploState? state;
  final VoidCallback? onOpenSettings;
  final ValueChanged<String>? onOpenChat;
  final VoidCallback? onAddContact;
  final VoidCallback? onNewChat;

  @override
  State<ChatsView> createState() => _ChatsViewState();
}

class _ChatsViewState extends State<ChatsView> {
  String _q = '';

  RipploState get _state => widget.state ?? api.state;

  void _add() => (widget.onAddContact ?? () => ui.add = const AddRequest())();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, locale]),
    builder: (context, _) {
      final s = _state;
      final q = _q.toLowerCase();
      final list = [
        for (final c in s.chats)
          if (c.name.toLowerCase().contains(q)) c,
      ];
      final requests = [
        for (final id in s.contacts.keys)
          if (s.contact(id) case final c?
              when c.request == 'in' && c.name.toLowerCase().contains(q))
            c,
      ];
      final profile = s.profile;
      final mq = MediaQuery.of(context);
      final centerH =
          mq.size.height -
          (mq.padding.top + kPageTop) -
          (mq.padding.bottom + kPageBottomReserve);
      return RPage(
        children: [
          RHdr(
            children: [
              RIconBtn(
                label: t('profile'),
                onTap: widget.onOpenSettings,
                child: Avatar(
                  name: profile?.name,
                  photo: profile?.avatar,
                  size: 36,
                ),
              ),
              RHdrTitle(t('chats')),
              RIconBtn(
                icon: LucideIcons.qrCode,
                label: t('addContact'),
                onTap: _add,
              ),
              RIconBtn(
                icon: LucideIcons.pencil,
                label: t('newChat'),
                onTap: widget.onNewChat ?? () => ui.newChat = 'chat',
              ),
            ],
          ),
          RField(
            search: true,
            hint: t('search'),
            label: t('search'),
            onChanged: (v) => setState(() => _q = v),
          ),
          if (requests.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: RBlock(
                children: [
                  RSection('${t('requests')} · ${requests.length}'),
                  const SizedBox(height: 1),
                  for (final c in requests)
                    RListRow(
                      children: [
                        Avatar(name: c.name, photo: c.avatar, shield: true),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RListName(c.name),
                              RListPrev(children: [Text(t('wantsToAdd'))]),
                            ],
                          ),
                        ),
                        RBtn(
                          text: t('decline'),
                          kind: RBtnKind.ghost,
                          sm: true,
                          onTap: () => api.declineRequest(c.id),
                        ),
                        RBtn(
                          text: t('accept'),
                          sm: true,
                          onTap: () => api.acceptRequest(c.id),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          if (s.chats.isEmpty && requests.isEmpty)
            SizedBox(
              height: centerH,
              child: DefaultTextStyle(
                style: rs(context, RipploText.body),
                textAlign: TextAlign.center,
                child: Padding(
                  padding: const EdgeInsets.all(kCenterPad),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: gapped(
                      [
                        Lucide(
                          LucideIcons.waves,
                          size: 72,
                          strokeWidth: 1,
                          color: context.rc.accent,
                        ),
                        RCenterText(t('emptyChats')),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [RBtn(text: t('addContact'), onTap: _add)],
                        ),
                      ],
                      kCenterGap,
                      vertical: true,
                    ),
                  ),
                ),
              ),
            ),
          for (final c in list) _row(context, s, c),
        ],
      );
    },
  );

  Widget _row(BuildContext context, RipploState s, Chat c) {
    final contact = s.contact(c.id);
    final shield = c.type == 'direct' && contact?.verification == 'none';
    final kind = c.lastKind;
    final prev = kind == 'voice'
        ? [Lucide(LucideIcons.mic, size: 14), Text(t('voiceMessage'))]
        : kind != null
        ? [Text(t(kind == 'video' ? 'videoMessage' : 'photoMessage'))]
        : c.lastText.isEmpty
        ? null
        : [Text(c.lastText)];
    return RListRow(
      onTap: () => widget.onOpenChat?.call(c.id),
      children: [
        Avatar(
          name: c.name,
          photo: contact?.avatar,
          group: c.type == 'group',
          shield: shield,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RListName(c.name),
              if (prev != null) RListPrev(children: prev),
            ],
          ),
        ),
        RListMeta(
          children: [
            Text(formatChatTime(c.lastTs)),
            if (c.unread > 0) RBadge('${c.unread}'),
          ],
        ),
      ],
    );
  }
}
