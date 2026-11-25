import 'package:material_ui/material_ui.dart';

import '../components/brand.dart';
import '../core/api.dart' as api;
import '../crypto/identity.dart' show RipploError;
import '../i18n.dart';
import '../mesh/bridge.dart';
import '../services/backup.dart';
import '../ui/widgets.dart';

class OnboardingView extends StatefulWidget {
  const OnboardingView({super.key, this.native, this.onRestored});

  final bool? native;
  final VoidCallback? onRestored;

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _restoring = false;
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _nameOk => _name.text.trim().isNotEmpty && !_busy;
  bool get _codeOk =>
      _code.text.replaceAll(RegExp(r'\D'), '').length == 30 && !_busy;

  Future<void> _go() async {
    if (!_nameOk) return;
    setState(() => _busy = true);
    try {
      await api.createProfile(_name.text.trim());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (!_codeOk) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await api.restoreBackup(_code.text.replaceAll(RegExp(r'\D'), ''));
      widget.onRestored?.call();
    } catch (e) {
      final code = e is RipploError ? e.code : null;
      if (mounted) {
        setState(
          () => _error = t(
            const ['bad_code', 'bad_file', 'need_factor'].contains(code)
                ? 'bk_$code'
                : 'bk_failed',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onCode(String v) {
    final g = groupCode(v);
    if (g != v) {
      _code.value = TextEditingValue(
        text: g,
        selection: TextSelection.collapsed(offset: g.length),
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: locale,
    builder: (context, _) {
      final c = context.rc;
      final native = widget.native ?? mesh.isNative;
      return ScrollCenter(
        children: [
          Lucide(LucideIcons.keyRound, size: 48, strokeWidth: 1.5, color: c.accent),
          Text(t('welcome'), style: brandH1(context)),
          RCenterText(t('onboardHint')),
          Narrow(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: gapped([
                RField(
                  controller: _name,
                  maxLength: 32,
                  hint: t('yourName'),
                  label: t('yourName'),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _go(),
                ),
                RBtn(
                  text: t('generateIdentity'),
                  onTap: _nameOk ? _go : null,
                ),
              ], 12, vertical: true),
            ),
          ),
          if (native && _restoring)
            Narrow(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: gapped([
                  Text(
                    t('restoreHint'),
                    textAlign: TextAlign.center,
                    style: rs(context, RipploText.body, c.text2),
                  ),
                  RField(
                    controller: _code,
                    hint: t('recoveryCode'),
                    label: t('recoveryCode'),
                    keyboardType: TextInputType.number,
                    onChanged: _onCode,
                    onSubmitted: (_) => _restore(),
                  ),
                  if (_error.isNotEmpty)
                    Text(
                      _error,
                      textAlign: TextAlign.center,
                      style: rs(context, RipploText.body, c.danger),
                    ),
                  RBtn(text: t('restore'), onTap: _codeOk ? _restore : null),
                ], 12, vertical: true),
              ),
            )
          else if (native)
            Narrow(
              child: RBtn(
                text: t('restoreFromBackup'),
                kind: RBtnKind.ghost,
                onTap: () => setState(() => _restoring = true),
              ),
            ),
        ],
      );
    },
  );
}
