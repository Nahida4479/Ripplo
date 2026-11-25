import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart' as api;
import '../../core/state.dart';
import '../../crypto/identity.dart' show RipploError, webLink;
import '../../i18n.dart';
import '../qr.dart';
import '../ui_state.dart';
import '../widgets.dart';
import '../../util/qrparts.dart';
import 'qr_scanner.dart';

typedef ScannerBuilder =
    Widget Function(ValueChanged<String> onCode, VoidCallback onError);

Widget _defaultScanner(ValueChanged<String> onCode, VoidCallback onError) =>
    QrScanner(onCode: onCode, onError: onError);

class AddContactSheet extends StatefulWidget {
  const AddContactSheet({
    super.key,
    this.state,
    this.onOpenContact,
    this.inviteLink,
    this.scanner = _defaultScanner,
  });

  final RipploState? state;
  final ValueChanged<String>? onOpenContact;
  final String Function()? inviteLink;
  final ScannerBuilder scanner;

  @override
  State<AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<AddContactSheet> {
  static const _cycle = Duration(milliseconds: 700);

  final _pasted = TextEditingController();
  String _tab = 'code';
  List<String> _parts = const [];
  String _link = '';
  int _frame = 0;
  String _progress = '';
  bool _busy = false;
  Assembler _assembler = createAssembler();
  Timer? _timer;
  Object? _seen;

  RipploState get _state => widget.state ?? api.state;
  bool get _verify => ui.add?.verify ?? false;

  @override
  void initState() {
    super.initState();
    _seen = ui.add;
    if (ui.add != null) _tab = _verify ? 'scan' : 'code';
    _sync();
    ui.addListener(_onUi);
  }

  @override
  void dispose() {
    ui.removeListener(_onUi);
    _timer?.cancel();
    _pasted.dispose();
    super.dispose();
  }

  void _onUi() {
    if (identical(ui.add, _seen)) return;
    _seen = ui.add;
    setState(() {
      _pasted.clear();
      if (ui.add != null) _tab = _verify ? 'scan' : 'code';
      _sync();
    });
  }

  void _setTab(String tab) => setState(() {
    _tab = tab;
    _sync();
  });

  void _sync() {
    _timer?.cancel();
    _timer = null;
    _busy = false;
    _progress = '';
    _assembler = createAssembler();
    if (ui.add == null || _tab != 'code') return;
    _link = widget.inviteLink?.call() ?? api.myInviteLink();
    _parts = splitLink(_link);
    _frame = 0;
    if (_parts.length > 1) {
      _timer = Timer.periodic(_cycle, (_) {
        if (mounted) setState(() => _frame = (_frame + 1) % _parts.length);
      });
    }
  }

  void _close() {
    _timer?.cancel();
    _timer = null;
    ui.add = null;
  }

  void _unbusy() =>
      Timer(const Duration(milliseconds: 1500), () => _busy = false);

  Future<void> _handle(String raw, String via) async {
    if (_busy) return;
    final part = _assembler.add(raw);
    var text = raw;
    if (part != null) {
      final have = part['have'];
      if (have != null) setState(() => _progress = '$have/${part['total']}');
      if (part['bad'] == true) {
        toast(t('err_bad_checksum'));
        setState(() => _progress = '');
      }
      final link = part['link'];
      if (link == null) return;
      text = link as String;
      setState(() => _progress = '');
    }
    _busy = true;
    try {
      if (_verify) {
        final ok = await api.verifyByQr(ui.add!.id!, text);
        if (ok) unawaited(HapticFeedback.lightImpact());
        toast(ok ? t('verifiedOk') : t('verifyMismatch'));
        if (!ok) {
          _unbusy();
          return;
        }
        _close();
      } else {
        final c = await api.addContactFromLink(text, via);
        unawaited(HapticFeedback.lightImpact());
        toast(t('added'));
        _close();
        if (c != null) widget.onOpenContact?.call(c.id);
      }
    } catch (e) {
      toast(t('err_${e is RipploError ? e.code : 'bad_link'}'));
      _unbusy();
    }
  }

  Future<void> _share() async {
    try {
      final text = '${t('inviteShareText')}\n${webLink(_link, locale.value)}';
      await SharePlus.instance.share(ShareParams(title: 'Ripplo', text: text));
    } catch (_) {}
  }

  Future<void> _paste() async {
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      if (d?.text != null) _pasted.text = d!.text!;
    } catch (_) {}
  }

  Widget _codeTab(BuildContext context) {
    final c = context.rc;
    final w = MediaQuery.of(context).size.width * .72;
    final hint = rs(context, RipploText.rowHint, c.text2);
    Widget hintText(String s, [double dy = _hintDy]) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kCenterTextMaxWidth),
      child: _Fit(
        height: 36.4,
        dy: dy,
        child: Text(s, textAlign: TextAlign.center, style: hint),
      ),
    );
    return DefaultTextStyle.merge(
      textAlign: TextAlign.center,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: gapped(
          [
            if (_parts.isNotEmpty)
              QrView(
                _parts[_frame],
                width: w < 280 ? w : 280,
                padding: 8,
                radius: 14,
                semanticLabel: t('myCode'),
              ),
            if (_parts.length > 1)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: gapped([
                  for (var i = 0; i < _parts.length; i++)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _frame ? c.accent : c.surface2,
                      ),
                      child: const SizedBox(width: 8, height: 8),
                    ),
                ], 6),
              ),
            if (_parts.length > 1) hintText(t('codeFramesHint')),
            _Fit(
              height: 21,
              dy: _nameDy,
              child: Text(
                _state.profile?.name ?? '',
                style: rs(
                  context,
                  RipploText.body,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            _Fit(
              height: 18.2,
              dy: _monoDy,
              child: RMono(
                _state.profile?.ripploId ?? '',
                style: RipploText.rowHint,
                color: c.text2,
              ),
            ),
            RBtn(block: true, onTap: _share, child: _up(t('inviteFriend'))),
            hintText(t('inviteHint'), -1.5),
          ],
          12,
          vertical: true,
        ),
      ),
    );
  }

  Widget _scanTab(BuildContext context) {
    final c = context.rc;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: ColoredBox(
          color: c.surface,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.scanner(
                (text) => unawaited(_handle(text, 'qr')),
                () => toast(t('cameraDenied')),
              ),
              CustomPaint(painter: _Viewfinder(c.accent)),
              if (_progress.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(kRadiusPill),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Text(
                          t('scanParts', {'n': _progress}),
                          style:
                              rs(
                                context,
                                RipploText.rowHint,
                                const Color(0xFFFFFFFF),
                              ).copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pasteTab(BuildContext context) {
    final th = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Theme(
          data: th.copyWith(
            textTheme: th.textTheme.copyWith(
              bodyLarge: th.textTheme.bodyLarge?.copyWith(letterSpacing: 0),
            ),
          ),
          child: RField(
            controller: _pasted,
            hint: t('pasteLink'),
            label: t('pasteLink'),
            keyboardType: TextInputType.url,
          ),
        ),
        const SizedBox(height: 12),
        RSheetActions(
          children: [
            RBtn(kind: RBtnKind.ghost, onTap: _paste, child: _up(t('paste'))),
            RBtn(
              onTap: _pasted.text.trim().isEmpty
                  ? null
                  : () => unawaited(_handle(_pasted.text.trim(), 'link')),
              child: _up(t('add')),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, ui, locale, _pasted]),
    builder: (context, _) {
      if (ui.add == null) return const SizedBox.shrink();
      final title = _verify ? t('verifyQr') : t('addContact');
      return RSheet(
        onDismiss: _close,
        label: title,
        children: [
          RSheetTitle(title),
          if (!_verify)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: RSeg<String>(
                options: [
                  ('code', t('myCode')),
                  ('scan', t('scan')),
                  ('paste', t('pasteLink')),
                ],
                value: _tab,
                onChanged: _setTab,
              ),
            ),
          if (_tab == 'code')
            _codeTab(context)
          else if (_tab == 'scan') ...[
            if (_verify) RSheetText(t('scanSafetyHint')),
            _scanTab(context),
          ] else
            _pasteTab(context),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: RBtn(
              kind: RBtnKind.ghost,
              block: true,
              onTap: _close,
              child: _up(t('close')),
            ),
          ),
        ],
      );
    },
  );
}

Widget _up(String text) =>
    Transform.translate(offset: const Offset(0, -.5), child: Text(text));

const _hintDy = -2.0;
const _nameDy = -2.0;
const _monoDy = -1.0;

class _Fit extends StatelessWidget {
  const _Fit({required this.height, required this.dy, required this.child});

  final double height;
  final double dy;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Transform.translate(offset: Offset(0, dy), child: child),
  );
}

class _Viewfinder extends CustomPainter {
  _Viewfinder(this.accent);

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromLTRBR(
      size.width * .18,
      size.height * .18,
      size.width * .82,
      size.height * .82,
      const Radius.circular(18),
    );
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(box),
      Paint()..color = const Color(0x73000000),
    );
    canvas.drawRRect(
      box.deflate(1.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = accent,
    );
  }

  @override
  bool shouldRepaint(_Viewfinder old) => old.accent != accent;
}
