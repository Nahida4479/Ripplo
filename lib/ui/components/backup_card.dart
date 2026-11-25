import 'package:material_ui/material_ui.dart';

import '../../i18n.dart';
import '../../mesh/bridge.dart' as bridge;
import '../ui_state.dart';
import '../widgets.dart';
import 'settings_parts.dart';

String localeDateTime(int ms, [String? loc]) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  final clock = '${two(d.minute)}:${two(d.second)}';
  if ((loc ?? locale.value) == 'pl') {
    return '${two(d.day)}.${two(d.month)}.${d.year}, ${two(d.hour)}:$clock';
  }
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${d.month}/${d.day}/${d.year}, $h:$clock ${d.hour < 12 ? 'AM' : 'PM'}';
}

class BackupCard extends StatefulWidget implements Margined {
  const BackupCard({super.key, this.mesh, this.backupMeta});

  final bridge.Mesh? mesh;
  final Map<String, Object?> Function()? backupMeta;

  @override
  double get marginTop => 16;

  @override
  double get marginBottom => kCardMarginBottom;

  @override
  State<BackupCard> createState() => _BackupCardState();
}

class _BackupCardState extends State<BackupCard> {
  Map<String, Object?> _status = const {
    'enabled': false,
    'lastAt': 0,
    'folder': null,
  };
  String? _step;
  String _code = '';
  bool _setup = false;
  String _check = '';
  bool _busy = false;
  final _input = TextEditingController();

  bridge.Mesh get _mesh => widget.mesh ?? bridge.mesh;

  List<String> get _groups => [
    for (final m in RegExp(r'.{1,5}').allMatches(_code)) m.group(0)!,
  ];

  @override
  void initState() {
    super.initState();
    if (_mesh.isNative) _refresh();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await _mesh.backupStatus();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      return;
    }
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      final code = e is bridge.MeshError ? e.code : null;
      if (code != 'cancelled') {
        toast(t(code == 'auth_failed' ? 'bk_auth_failed' : 'bk_failed'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _close() => setState(() {
    _step = null;
    _code = '';
    _check = '';
    _input.clear();
  });

  Future<void> _enable() => _run(() async {
    final code = await _mesh.backupEnable();
    setState(() {
      _code = code;
      _setup = true;
      _step = 'code';
    });
    await _refresh();
  });

  Future<void> _show() => _run(() async {
    final code = await _mesh.backupShowCode();
    setState(() {
      _code = code;
      _setup = false;
      _step = 'code';
    });
  });

  void _wrote() => setState(() {
    _check = '';
    _input.clear();
    _step = 'check';
  });

  void _verify() {
    if (_check.replaceAll(RegExp(r'\D'), '') != _groups.last) {
      toast(t('codeMismatch'));
      return;
    }
    setState(() {
      _code = '';
      _step = 'folder';
    });
  }

  Future<void> _folder() => _run(() async {
    await _mesh.backupChooseFolder();
    _close();
    await _refresh();
  });

  Future<void> _now() => _run(() async {
    if (!await _mesh.authenticate(t('unlockReason'))) return;
    await _mesh.backupCreate('now', widget.backupMeta?.call() ?? const {});
    toast(t('backupDone'));
    await _refresh();
  });

  void _off() => ui.confirm = ConfirmRequest(
    title: t('backupOff'),
    text: t('backupOffConfirm'),
    ok: t('backupOff'),
    danger: true,
    onOk: () => _run(() async {
      await _mesh.backupDisable();
      await _refresh();
    }),
  );

  Widget _bold(String text) => Text(
    text,
    style: rs(context, RipploText.body.copyWith(fontWeight: FontWeight.w700)),
  );

  Widget _hint(String text) =>
      Text(text, style: rs(context, RipploText.rowHint, context.rc.text2));

  Widget _acts(List<Widget> kids) =>
      Row(children: gapped([for (final k in kids) Expanded(child: k)], 8));

  Widget _stack(List<Widget> kids) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: gapped(kids, 12, vertical: true),
  );

  Widget _codeGrid() {
    final c = context.rc;
    final g = _groups;
    Widget cell(String s) => Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        s,
        style: monoStyle(
          context,
          const TextStyle(
            fontSize: 22,
            height: 1.4,
            fontWeight: FontWeight.w600,
            letterSpacing: 22 * .08,
          ),
        ),
      ),
    );
    return Semantics(
      label: t('codeTitle'),
      child: Column(
        children: gapped(
          [
            for (var i = 0; i < g.length; i += 2)
              Row(
                children: [
                  Expanded(child: cell(g[i])),
                  const SizedBox(width: 8),
                  Expanded(
                    child: i + 1 < g.length ? cell(g[i + 1]) : const SizedBox(),
                  ),
                ],
              ),
          ],
          8,
          vertical: true,
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (!_mesh.isNative) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FracText(
            t('backupWeb'),
            rs(context, RipploText.rowHint, context.rc.text2),
            dy: -2,
          ),
        ),
      ];
    }
    switch (_step) {
      case 'code':
        return [
          _bold(t('codeTitle')),
          const SizedBox(height: 12),
          _codeGrid(),
          const SizedBox(height: 12),
          if (_setup) ...[
            _hint(t('codeWarn')),
            const SizedBox(height: 8),
            RBtn(text: t('codeWritten'), block: true, onTap: _wrote),
          ] else
            RBtn(text: t('done'), block: true, onTap: _close),
        ];
      case 'check':
        return [
          _stack([
            _bold(t('codeCheckTitle')),
            _hint(t('codeCheckHint')),
            RField(
              controller: _input,
              maxLength: 5,
              keyboardType: TextInputType.number,
              label: t('codeCheckTitle'),
              onChanged: (v) => setState(() => _check = v),
              onSubmitted: (_) => _verify(),
            ),
            _acts([
              RBtn(
                text: t('back'),
                kind: RBtnKind.ghost,
                block: true,
                onTap: () => setState(() => _step = 'code'),
              ),
              RBtn(
                text: t('continue'),
                block: true,
                onTap: _check.length < 5 ? null : _verify,
              ),
            ]),
          ]),
        ];
      case 'folder':
        return [
          _stack([
            _bold(t('folderTitle')),
            _hint(t('folderHint')),
            _acts([
              RBtn(
                text: t('notNow'),
                kind: RBtnKind.ghost,
                block: true,
                onTap: _close,
              ),
              RBtn(
                text: t('chooseFolder'),
                block: true,
                onTap: _busy ? null : _folder,
              ),
            ]),
          ]),
        ];
    }
    if (_status['enabled'] != true) {
      return [
        _stack([
          _hint(t('backupIntro')),
          RBtn(
            text: t('backupEnable'),
            block: true,
            onTap: _busy ? null : _enable,
          ),
        ]),
      ];
    }
    final lastAt = _status['lastAt'];
    final folder = _status['folder'];
    final body = rs(context, RipploText.body);
    return [
      _stack([
        Text.rich(
          TextSpan(
            style: body,
            children: [
              TextSpan(
                text: lastAt is num && lastAt != 0
                    ? t('backupLast', {'time': localeDateTime(lastAt.toInt())})
                    : t('backupNever'),
              ),
              const TextSpan(text: '\n'),
              TextSpan(
                text: folder is String && folder.isNotEmpty
                    ? t('backupFolder', {'name': folder})
                    : t('backupNoFolder'),
                style: rs(context, RipploText.rowHint, context.rc.text2),
              ),
            ],
          ),
        ),
        _hint(t('codeWarn')),
        _acts([
          RBtn(text: t('backupNow'), block: true, onTap: _busy ? null : _now),
          RBtn(
            text: t('chooseFolder'),
            kind: RBtnKind.ghost,
            block: true,
            onTap: _busy ? null : _folder,
          ),
        ]),
        _acts([
          RBtn(
            text: t('showCode'),
            kind: RBtnKind.ghost,
            block: true,
            onTap: _busy ? null : _show,
          ),
          RBtn(
            text: t('backupOff'),
            kind: RBtnKind.danger,
            block: true,
            onTap: _busy ? null : _off,
          ),
        ]),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: locale,
    builder: (context, _) => RBlock(
      children: [
        SectionHead(t('backup')),
        RCard(
          pad: true,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _body(),
            ),
          ],
        ),
      ],
    ),
  );
}
