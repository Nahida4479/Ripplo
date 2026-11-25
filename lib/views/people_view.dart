import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/api.dart' as api;
import '../core/state.dart';
import '../crypto/identity.dart';
import '../i18n.dart';
import '../mesh/bridge.dart';
import '../ui/ui_state.dart';
import '../ui/widgets.dart';
import '../util/js.dart';
import '../util/link_label.dart';

const Map<String, String> _medium = {
  'ble': 'BLE',
  'lan': 'LAN',
  'wifi_direct': 'Wi-Fi Direct',
  'wifi-direct': 'Wi-Fi Direct',
  'wifidirect': 'Wi-Fi Direct',
  'aware': 'Wi-Fi Aware',
  'wifi-aware': 'Wi-Fi Aware',
  'multipeer': 'Multipeer',
  'l2cap': 'BLE',
};

String _mediumName(Object? m) => _medium['$m'.toLowerCase()] ?? '$m';

String _linkName(Object? l) =>
    isCodedLink(l) ? 'BLE Coded' : _mediumName(l is Map ? l['medium'] : null);

class _Chip {
  const _Chip(this.name, this.active, this.dim);
  final String name;
  final bool active;
  final bool dim;
}

List<_Chip> _chips(Neighbor n) {
  final links = n['links'];
  final src = links is List && links.isNotEmpty
      ? links.cast<Object?>()
      : <Object?>[n];
  final linked = <String>[];
  for (final l in src) {
    final s = _linkName(l);
    if (!linked.contains(s)) linked.add(s);
  }
  final seenRaw = n['seen'];
  final seen = <String>[];
  if (seenRaw is List) {
    for (final m in seenRaw) {
      final s = _mediumName(m);
      if (!seen.contains(s) && !linked.contains(s)) seen.add(s);
    }
  }
  return [
    for (var i = 0; i < linked.length; i++) _Chip(linked[i], i == 0, false),
    for (final s in seen) _Chip(s, false, true),
  ];
}

String _clock(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  if (locale.value == 'pl') return '${two(d.hour)}:${two(d.minute)}';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${two(h)}:${two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
}

class _Up extends StatelessWidget {
  const _Up(this.dy, this.child);

  final double dy;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Transform.translate(offset: Offset(0, -dy), child: child);
}

class _Gap extends StatelessWidget implements Margined {
  const _Gap({required this.child, this.top = 0, this.bottom = 0});

  final Widget child;
  final double top;
  final double bottom;

  @override
  double get marginTop => top;

  @override
  double get marginBottom => bottom;

  @override
  Widget build(BuildContext context) => child;
}

class _LinkChip extends StatelessWidget {
  const _LinkChip(this.text, this.active);

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kChipPadX,
        vertical: kChipPadY,
      ),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: gapped([
          Text(text, style: rs(context, RipploText.chip, c.text2)),
          if (active)
            Lucide(LucideIcons.check, size: 12, strokeWidth: 2, color: c.ok),
        ], kChipGap),
      ),
    );
  }
}

class _FindField extends StatelessWidget {
  const _FindField({
    required this.controller,
    required this.hint,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final style = rs(context, RipploText.body).copyWith(letterSpacing: 0);
    return Container(
      constraints: const BoxConstraints(minHeight: kFieldMin),
      padding: const EdgeInsets.symmetric(horizontal: kFieldPadX),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border, width: kBorderWidth),
        borderRadius: BorderRadius.circular(kRadiusField),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: TextField(
          controller: controller,
          enabled: enabled,
          maxLength: 40,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSubmitted(),
          style: style,
          cursorColor: c.text,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.only(bottom: 3.5),
            counterText: '',
            hintText: hint,
            hintStyle: style.copyWith(color: const Color(0xFF757575)),
          ),
        ),
      ),
    );
  }
}

class PeopleView extends StatefulWidget {
  const PeopleView({super.key, this.state, this.live = true});

  final RipploState? state;
  final bool live;

  @override
  State<PeopleView> createState() => _PeopleViewState();
}

class _PeopleViewState extends State<PeopleView> {
  final _q = TextEditingController();
  Timer? _timer;

  RipploState get _state => widget.state ?? api.state;

  @override
  void initState() {
    super.initState();
    if (widget.live) {
      _sync();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _sync());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    try {
      for (final f in await mesh.getNeighbors()) {
        final cur = _state.neighbors
            .where((n) => n.node == f['node'])
            .firstOrNull;
        if (cur != null) {
          cur['links'] = f['links'];
          cur['seen'] = f['seen'];
        }
      }
    } catch (_) {}
  }

  bool _isContact(String id) {
    final c = _state.contact(id);
    return c != null && c.request == null;
  }

  String? _request(String id) => _state.contact(id)?.request;

  String _nameOf(Neighbor n) {
    final card = n['card'];
    if (card is Map && truthy(card['name'])) return '${card['name']}';
    for (final k in _state.contacts.keys) {
      final c = _state.contact(k);
      if (c != null &&
          truthy(n.node) &&
          c['node'] == n.node &&
          c.request == null &&
          truthy(c.name)) {
        return c.name;
      }
    }
    return t('unknownPerson');
  }

  void _invite(Person p) {
    ui.confirm = ConfirmRequest(
      title: t('inviteTitle', {'name': p.name}),
      text: t('inviteText'),
      ok: t('invite'),
      onOk: () async {
        try {
          await api.invite(p);
          toast(t('inviteSent'));
        } catch (e) {
          final code = e is RipploError
              ? e.code
              : e is MeshError
              ? e.code
              : 'bad_link';
          toast(t('err_${truthy(code) ? code : 'bad_link'}'));
        }
      },
    );
  }

  Future<void> _accept(String id) async {
    try {
      await api.acceptRequest(id);
    } catch (e) {
      toast(
        e is RipploError
            ? e.message
            : e is MeshError
            ? e.message
            : '$e',
      );
    }
  }

  void _find() {
    final s = _state;
    if (s.peopleRefreshing || _q.text.trim().isEmpty) return;
    api.searchPeople(_q.text);
  }

  void _clear() {
    _q.text = '';
    api.searchPeople('');
  }

  Widget _action(
    BuildContext context,
    String id, {
    required bool contact,
    VoidCallback? add,
  }) {
    final req = _request(id);
    if (contact) {
      return Lucide(
        LucideIcons.check,
        size: 22,
        strokeWidth: 2,
        color: context.rc.ok,
        semanticLabel: t('inContacts'),
      );
    }
    if (req == 'in') {
      return IntrinsicWidth(
        child: RBtn(
          sm: true,
          onTap: () => _accept(id),
          child: _Up(1.5, Text(t('accept'))),
        ),
      );
    }
    if (req == 'out' && !(_state.contact(id)?.inviteFailed ?? false)) {
      return RChip(t('invited'));
    }
    return IntrinsicWidth(
      child: RBtn(
        sm: true,
        onTap: add,
        child: _Up(1.5, Text(req != null ? t('retry') : t('invite'))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, locale, _q]),
    builder: (context, _) {
      final s = _state;
      final c = context.rc;
      final refreshing = s.peopleRefreshing;
      final query = s.peopleQuery.isNotEmpty;
      final last = s.peopleRefreshedAt != 0 ? _clock(s.peopleRefreshedAt) : '–';
      final canFind = !refreshing && _q.text.trim().isNotEmpty;
      return RPage(
        children: [
          RHdr(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t('people'), style: rs(context, RipploText.h1)),
                    _Up(
                      1,
                      Text(
                        '${t('lastRefreshed', {'time': last})} ${t('nextTonight')}',
                        style: rs(context, RipploText.sub, c.text2),
                      ),
                    ),
                  ],
                ),
              ),
              RIconBtn(
                icon: LucideIcons.refreshCw,
                spin: refreshing,
                label: t('refresh'),
                onTap: refreshing ? null : () => fire(api.refreshPeople()),
              ),
            ],
          ),
          _Gap(
            bottom: 4,
            child: Row(
              children: gapped([
                Expanded(
                  child: _FindField(
                    controller: _q,
                    hint: t('findPlaceholder'),
                    enabled: !refreshing,
                    onSubmitted: _find,
                  ),
                ),
                if (query)
                  RIconBtn(
                    icon: LucideIcons.x,
                    size: 20,
                    stroke: 2,
                    label: t('close'),
                    onTap: _clear,
                  ),
                RIconBtn(
                  icon: LucideIcons.search,
                  label: t('find'),
                  onTap: canFind ? _find : null,
                ),
              ], 4),
            ),
          ),
          _Gap(
            bottom: 8,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _Up(
                1,
                Text(
                  t('findHint'),
                  style: rs(context, RipploText.sub, c.text2),
                ),
              ),
            ),
          ),
          _Gap(top: 16, bottom: 8, child: _Up(2.5, RSection(t('nearby')))),
          RCard(
            children: [
              if (s.neighbors.isEmpty) _Up(1, REmpty(t('nobodyNearby'))),
              for (final n in s.neighbors) _nearbyRow(context, s, n),
            ],
          ),
          _Gap(
            top: 16,
            bottom: 8,
            child: _Up(2.5, RSection(query ? t('searchResults') : t('inMesh'))),
          ),
          RCard(
            children: [
              if (s.people.isEmpty)
                _Up(
                  1,
                  REmpty(
                    query && !refreshing ? t('noResults') : t('nobodyInMesh'),
                  ),
                ),
              for (final p in s.people) _personRow(context, s, p),
            ],
          ),
        ],
      );
    },
  );

  Widget _nearbyRow(BuildContext context, RipploState s, Neighbor n) {
    final card = n['card'];
    final cm = card is Map ? card : null;
    final cid = cm == null ? null : '${cm['id']}';
    final name = _nameOf(n);
    final chips = _chips(n);
    Widget? action;
    if (cid == null || cm == null) {
      action = RHint(t('waitingCard'));
    } else {
      action = _action(
        context,
        cid,
        contact: _isContact(cid),
        add: () => _invite(
          Person(
            s.map({
              'id': cid,
              'name': cm['name'],
              'card': cm['card'],
              'hops': 0,
            }),
          ),
        ),
      );
    }
    return RRow(
      children: [
        Avatar(
          name: name,
          photo: cid != null ? s.contact(cid)?.avatar : '',
          size: 40,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Up(1.75, RLabel(name)),
              SizedBox(
                height: 21.5,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 0.5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        for (final ch in chips)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Opacity(
                              opacity: ch.dim ? .55 : 1,
                              child: _LinkChip(ch.name, ch.active),
                            ),
                          ),
                        const SizedBox(width: 4),
                        Flexible(child: RHint('${n.kbps} kbps')),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        action,
      ],
    );
  }

  Widget _personRow(BuildContext context, RipploState s, Person p) => RRow(
    children: [
      Avatar(name: p.name, photo: s.contact(p.id)?.avatar, size: 40),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Up(1.75, RLabel(p.name)),
            SizedBox(
              height: 21.7,
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 0.6),
                  child: RHint(t('hops', {'n': p.hops})),
                ),
              ),
            ),
          ],
        ),
      ),
      _action(
        context,
        p.id,
        contact: p.isContact || _isContact(p.id),
        add: () => _invite(p),
      ),
    ],
  );
}
