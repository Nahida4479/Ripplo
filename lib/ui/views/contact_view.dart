import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/api.dart' as api;
import '../../core/state.dart';
import '../../i18n.dart';
import '../qr.dart';
import '../ui_state.dart';
import '../widgets.dart';
import '../../util/js.dart';

String _date(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  if (locale.value == 'pl') return '${two(d.day)}.${two(d.month)}.${d.year}';
  return '${d.month}/${d.day}/${d.year}';
}

List<String> _groups(String digits) => [
  for (var i = 0; i < digits.length; i += 5)
    digits.substring(i, i + 5 > digits.length ? digits.length : i + 5),
];

class _Up extends StatelessWidget {
  const _Up(this.dy, this.child);

  final double dy;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Transform.translate(offset: Offset(0, -dy), child: child);
}

class _Sec extends StatelessWidget implements Margined {
  const _Sec(this.text, {this.bottom = 8});

  final String text;
  final double bottom;

  @override
  double get marginTop => 16;

  @override
  double get marginBottom => bottom;

  @override
  Widget build(BuildContext context) => _Up(2, RSection(text));
}

class ContactView extends StatefulWidget {
  const ContactView({
    super.key,
    required this.id,
    this.state,
    this.onBack,
    this.onDeleted,
    this.safety,
    this.live = true,
  });

  final String id;
  final RipploState? state;
  final VoidCallback? onBack;
  final VoidCallback? onDeleted;
  final Future<String> Function(String id)? safety;
  final bool live;

  @override
  State<ContactView> createState() => _ContactViewState();
}

class _ContactViewState extends State<ContactView> {
  String _digits = '';
  bool _loading = false;
  Msg? _viewing;

  RipploState get _state => widget.state ?? api.state;

  @override
  void initState() {
    super.initState();
    if (widget.live) fire(api.loadMessages(widget.id));
  }

  void _ensureDigits(bool show) {
    if (!show || _digits.isNotEmpty || _loading) return;
    _loading = true;
    (widget.safety ?? api.safetyNumber)(widget.id).then(
      (d) {
        _loading = false;
        if (mounted) setState(() => _digits = d);
      },
      onError: (Object _, StackTrace _) {
        _loading = false;
      },
    );
  }

  List<Msg> _media() {
    final list = [
      for (final m in _state.msgs(widget.id) ?? const <Msg>[])
        if (m.att case final a?
            when (a.kind == 'image' || a.kind == 'video') &&
                (a.bytes != null || truthy(a.path)))
          m,
    ];
    list.sort((a, b) => b.ts.compareTo(a.ts));
    return list;
  }

  Future<void> _retry() async {
    toast(
      await api.verifyNearby(widget.id) ? t('verifiedOk') : t('verifyFailed'),
    );
  }

  void _sure() {
    ui.confirm = ConfirmRequest(
      title: t('imSure'),
      text: t('imSureConfirm'),
      ok: t('confirm'),
      onOk: () => api.markVerified(widget.id),
    );
  }

  void _delete() {
    ui.confirm = ConfirmRequest(
      title: t('deleteContact'),
      text: t('deleteContactConfirm'),
      ok: t('delete'),
      danger: true,
      onOk: () async {
        await api.deleteContact(widget.id);
        widget.onDeleted?.call();
      },
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, locale]),
    builder: (context, _) {
      final c = _state.contact(widget.id);
      if (c == null) return const SizedBox.shrink();
      final rc = context.rc;
      final verified = c.m['verification'] != 'none';
      final conflict = c.conflict;
      final showSafety = !verified || conflict;
      _ensureDigits(showSafety);
      final media = _media();
      final hint = rs(context, RipploText.rowHint, rc.text2);
      final tint = conflict ? rc.danger : (verified ? rc.ok : rc.warn);
      final body = [
        RHdr(
          children: [
            RIconBtn(
              icon: LucideIcons.chevronLeft,
              size: 24,
              stroke: 2,
              label: t('back'),
              onTap: widget.onBack,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 20),
          child: Column(
            children: gapped(
              [
                Avatar(name: c.name, photo: c.avatar, size: 88),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _Up(
                    1,
                    Text(
                      c.name,
                      textAlign: TextAlign.center,
                      style: rs(context, RipploText.h1).copyWith(fontSize: 24),
                    ),
                  ),
                ),
                Text(
                  c.id,
                  style: monoStyle(context, RipploText.rowHint, rc.text2),
                ),
              ],
              6,
              vertical: true,
            ),
          ),
        ),
        _statusCard(
          context,
          c,
          verified: verified,
          conflict: conflict,
          tint: tint,
          hint: hint,
        ),
        _Sec(media.isEmpty ? t('media') : '${t('media')} · ${media.length}'),
        RCard(
          pad: true,
          children: [
            if (media.isEmpty)
              _Up(1.5, Text(t('noMedia'), style: rs(context, RipploText.body)))
            else
              _grid(context, media),
          ],
        ),
        if (showSafety) _Sec(t('safetyNumber'), bottom: 9),
        if (showSafety) _safetyCard(context, hint),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped(
            [
              if (showSafety)
                RBtn(
                  block: true,
                  text: t('verifyQr'),
                  onTap: () =>
                      ui.add = AddRequest(mode: 'verify', id: widget.id),
                ),
              if (showSafety)
                RBtn(
                  block: true,
                  kind: RBtnKind.ghost,
                  text: t(
                    c.verifyState == 'checking' ? 'checking' : 'retryNearby',
                  ),
                  onTap: c.verifyState == 'checking'
                      ? null
                      : () => fire(_retry()),
                ),
              if (!verified)
                RBtn(
                  block: true,
                  kind: RBtnKind.ghost,
                  text: t('imSure'),
                  onTap: _sure,
                ),
              RBtn(
                block: true,
                kind: RBtnKind.danger,
                text: t('deleteContact'),
                onTap: _delete,
              ),
            ],
            8,
            vertical: true,
          ),
        ),
      ];
      final mq = MediaQuery.paddingOf(context);
      return Stack(
        fit: StackFit.expand,
        children: [
          DefaultTextStyle(
            style: rs(context, RipploText.body),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: rc.bg),
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  height: kGlowHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: rc.pageGradient),
                  ),
                ),
                SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    kPagePadX,
                    mq.top + kPageTop,
                    kPagePadX,
                    mq.bottom + 24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: vstack(body, edges: true),
                  ),
                ),
              ],
            ),
          ),
          if (_viewing != null) _viewer(context, mq),
        ],
      );
    },
  );

  Widget _statusCard(
    BuildContext context,
    Contact c, {
    required bool verified,
    required bool conflict,
    required Color tint,
    required TextStyle hint,
  }) {
    final label = rs(
      context,
      RipploText.rowLabel,
    ).copyWith(fontWeight: FontWeight.w600);
    final title = conflict
        ? t('conflict')
        : (verified ? t('verified') : t('notVerified'));
    final lines = [
      if (verified)
        '${t('method_${c.m['verification']}')} · ${c.verifiedAt != 0 ? _date(c.verifiedAt) : ''}'
      else
        t('unverifiedWarning'),
      if (c.peerVerified != null && !verified)
        t('peerVerified', {
          'name': c.name,
          'method': t('method_${c.peerVerified!['level']}'),
        }),
    ];
    double width(String s, TextStyle st) {
      final p = TextPainter(
        text: TextSpan(text: s, style: st),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    var textW = width(title, label);
    for (final l in lines) {
      final w = width(l, hint);
      if (w > textW) textW = w;
    }
    final avail =
        MediaQuery.sizeOf(context).width -
        2 * kPagePadX -
        2 * kBorderWidth -
        2 * kPad;
    final over = 28 + 12 + textW - avail;
    final iconW = over > 0 ? 28 - over * 28 / (28 + textW) : 28.0;
    return RCard(
      pad: true,
      borderColor: conflict ? context.rc.danger : null,
      children: [
        Row(
          children: gapped([
            SizedBox(
              width: iconW,
              height: 28,
              child: Center(
                child: Lucide(
                  verified && !conflict
                      ? LucideIcons.shieldCheck
                      : LucideIcons.shieldAlert,
                  size: iconW,
                  strokeWidth: 2,
                  color: tint,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Up(1, Text(title, style: label)),
                  _Up(
                    1,
                    Text(
                      lines.join('\n'),
                      style: hint.copyWith(height: 18 / 13),
                    ),
                  ),
                ],
              ),
            ),
          ], 12),
        ),
      ],
    );
  }

  Widget _safetyCard(BuildContext context, TextStyle hint) {
    final groups = _groups(_digits);
    final rows = [
      for (var i = 0; i < groups.length; i += 4)
        groups.sublist(i, i + 4 > groups.length ? groups.length : i + 4),
    ];
    return RCard(
      pad: true,
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 15.2),
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: gapped(
                    [
                      for (final r in rows)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: gapped([
                            for (final g in r)
                              SizedBox(
                                height: 22,
                                child: Text(
                                  g,
                                  style: monoStyle(
                                    context,
                                    RipploText.body.copyWith(fontSize: 16),
                                  ),
                                ),
                              ),
                          ], 14),
                        ),
                    ],
                    6,
                    vertical: true,
                  ),
                ),
              ),
            ),
            if (_digits.isNotEmpty)
              QrView(
                _digits,
                width: 230,
                padding: 6,
                radius: 12,
                semanticLabel: t('safetyNumber'),
              ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 1.5),
              child: Text(
                t('safetyHint'),
                textAlign: TextAlign.center,
                style: hint,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, Msg m) {
    final a = m.att!;
    final rc = context.rc;
    Widget inner;
    if (a.kind == 'image') {
      inner = a.bytes != null
          ? Image.memory(a.bytes!, fit: BoxFit.cover, gaplessPlayback: true)
          : Image.file(File(a.path!), fit: BoxFit.cover, gaplessPlayback: true);
    } else {
      inner = Center(
        child: Lucide(
          LucideIcons.play,
          size: 22,
          strokeWidth: 2,
          color: const Color(0xFFFFFFFF),
        ),
      );
    }
    return Pressable(
      onTap: () => setState(() => _viewing = m),
      label: t(a.kind == 'video' ? 'videoMessage' : 'photoMessage'),
      builder: (_, _) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: rc.surface2,
          child: SizedBox.expand(child: inner),
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, List<Msg> media) => LayoutBuilder(
    builder: (context, box) {
      final w = (box.maxWidth - 8) / 3;
      return Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final m in media)
            SizedBox(width: w, height: w, child: _tile(context, m)),
        ],
      );
    },
  );

  Widget _viewer(BuildContext context, EdgeInsets pad) {
    final a = _viewing!.att!;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _viewing = null),
        child: ColoredBox(
          color: const Color(0xEB000000),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  pad.top + 56,
                  12,
                  pad.bottom + 12,
                ),
                child: Center(
                  child: a.kind == 'image'
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: a.bytes != null
                              ? Image.memory(a.bytes!, fit: BoxFit.contain)
                              : Image.file(File(a.path!), fit: BoxFit.contain),
                        )
                      : Lucide(
                          LucideIcons.play,
                          size: 48,
                          strokeWidth: 2,
                          color: const Color(0xFFFFFFFF),
                        ),
                ),
              ),
              Positioned(
                top: pad.top + 8,
                right: 8,
                child: RIconBtn(
                  icon: LucideIcons.x,
                  size: 24,
                  stroke: 2,
                  color: const Color(0xFFFFFFFF),
                  label: t('close'),
                  onTap: () => setState(() => _viewing = null),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
