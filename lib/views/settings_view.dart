import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/backup_card.dart';
import '../contributors.dart';
import '../core/api.dart' as api;
import '../core/diag.dart';
import '../core/state.dart';
import '../crypto/identity.dart' show RipploError;
import '../i18n.dart';
import '../mesh/bridge.dart' as bridge;
import '../services/theme.dart';
import '../ui/ui_state.dart';
import '../ui/widgets.dart';
import '../util/avatar.dart' show settingsInitials;
import '../util/js.dart' as js;
import '../util/link_label.dart';

const String _repo = 'https://github.com/Nahida4479/Ripplo';
const String _devLogRecipient = '8277SCA2VX64NHHB';
const List<String> _specs = [
  'lan',
  'wifi-direct',
  'wifi-aware',
  'ble:1m',
  'ble:coded',
];
const Map<String, String> _specNames = {
  'lan': 'LAN',
  'wifi-direct': 'Wi-Fi Direct',
  'wifi-aware': 'Wi-Fi Aware',
  'ble:1m': 'BLE 1M PHY',
  'ble:coded': 'BLE Coded PHY',
};
final RegExp _hex6 = RegExp(r'^#[0-9a-fA-F]{6}$');

String _linkLabel(Map l) => isCodedLink(l)
    ? 'BLE Coded'
    : (l['medium'] == null ? 'UNDEFINED' : '${l['medium']}'.toUpperCase());

String _num(Object? v) => v is num
    ? (v == v.truncate() ? '${v.truncate()}' : '$v')
    : '${v ?? 'undefined'}';

String _kbps(Neighbor n) => n.kbps >= 1000
    ? '${(n.kbps / 1000).toStringAsFixed(1)} Mbps'
    : '${_num(n.kbps)} kbps';

String _nodeName(Neighbor n) {
  final card = n['card'];
  final name = card is Map ? card['name'] : null;
  return js.truthy(name)
      ? '$name'
      : n.node.substring(0, n.node.length.clamp(0, 8));
}

List<Map> _links(Object? v) =>
    v is List && v.isNotEmpty ? [for (final l in v) l as Map] : const [];

String _clock(int at) {
  final d = DateTime.fromMillisecondsSinceEpoch(at);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

Color _lineColor(RipploColors c, String ln) {
  if (RegExp(r' ! |\bfailed\b|\brejected\b').hasMatch(ln)) return c.danger;
  if (RegExp(r'\bclosed\b|\btimeout\b').hasMatch(ln)) return c.warn;
  if (RegExp(
    r'\bstarted\b|\blinked\b|\bconnected\b|advertising',
  ).hasMatch(ln)) {
    return c.ok;
  }
  return c.text2;
}

Color _stageColor(RipploColors c, String? s) => switch (s) {
  'started' || 'linked' || 'connected' => c.ok,
  'closed' || 'timeout' => c.warn,
  'failed' || 'rejected' => c.danger,
  _ => c.text2,
};

StrutStyle get _strut => StrutStyle(
  fontFamily: debugFontFamily,
  fontSize: 15,
  height: 1.4,
  leadingDistribution: TextLeadingDistribution.even,
  forceStrutHeight: true,
);

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.theme,
    this.state,
    this.mesh,
    this.controller,
    this.android,
    this.backupMeta,
    this.onCheckUpdate,
    this.onInstall,
    this.onSetAppLock,
    this.onPickAvatar,
    this.onPickColor,
    this.onOpenUrl,
    this.onMyCode,
  });

  final ThemeController theme;
  final RipploState? state;
  final bridge.Mesh? mesh;
  final ScrollController? controller;
  final bool? android;
  final Map<String, Object?> Function()? backupMeta;
  final Future<void> Function(bool manual)? onCheckUpdate;
  final Future<void> Function()? onInstall;
  final Future<void> Function(bool on)? onSetAppLock;
  final Future<String?> Function()? onPickAvatar;
  final Future<String?> Function(String current)? onPickColor;
  final ValueChanged<String>? onOpenUrl;
  final VoidCallback? onMyCode;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String? _draft;
  final _draftCtl = TextEditingController();
  Timer? _logTimer;
  Timer? _devTimer;
  int _devTaps = 0;
  String? _openId;
  String? _openNode;
  List<String> _detail = const [];
  String _devLog = '';
  ({bool coded, bool extended}) _bleCaps = (coded: false, extended: false);
  List<Map<String, Object?>> _devTransports = const [];
  List<Map<String, Object?>> _stageLog = const [];
  final Map<String, String> _forceSpec = {};
  final Map<String, bool> _broken = {};
  bridge.Unsub? _offStage;

  RipploState get _state => widget.state ?? api.state;
  bridge.Mesh get _mesh => widget.mesh ?? bridge.mesh;
  bool get _android => widget.android ?? (!kIsWeb && Platform.isAndroid);

  @override
  void initState() {
    super.initState();
    _offStage = _mesh.on('devStage', (e) {
      if (!mounted) return;
      final at = e['at'];
      final row = {...e, 'time': _clock(at is num ? at.toInt() : js.now())};
      setState(() => _stageLog = [row, ...(_stageLog)].take(100).toList());
    });
    if (_state.settings.dev) _loadDev();
  }

  @override
  void dispose() {
    _offStage?.call();
    _logTimer?.cancel();
    _devTimer?.cancel();
    _draftCtl.dispose();
    super.dispose();
  }

  void _open(String url) {
    final f = widget.onOpenUrl;
    if (f != null) {
      f(url);
      return;
    }
    unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));
  }

  Future<String> _summary() async {
    var out = '--- summary ---\n';
    try {
      out += await _mesh.getDeviceInfo();
    } catch (_) {}
    try {
      final tr = await _mesh.getTransports();
      out +=
          'transports ${tr.map((x) => '${x['name']}:${js.truthy(x['running'])
              ? 'running'
              : js.truthy(x['unsupported'])
              ? 'unsupported'
              : 'stopped'}').join(' ')}\n';
    } catch (_) {}
    final nb = _state.neighbors;
    out +=
        'neighbors ${nb.isNotEmpty ? nb.map((n) {
                final links = _links(n['links']);
                final via = links.isNotEmpty ? links.map((l) => l['medium']).join('+') : n.medium;
                return '${n.node.substring(0, n.node.length.clamp(0, 8))}/$via${js.truthy(n['card']) ? '' : '/nocard'}';
              }).join(' ') : 'none'}\n';
    return out;
  }

  Future<void> _sendLogs() async {
    _logTimer = null;
    final native = await _mesh.getDiag();
    final head =
        'Ripplo ${_state.update.current.isEmpty ? '?' : _state.update.current} ${DateTime.fromMillisecondsSinceEpoch(js.now(), isUtc: true).toIso8601String()}\n';
    final text =
        '$head${await _summary()}--- native log ---\n${native.isNotEmpty ? '$native\n--- JS ---\n' : ''}${diagText()}';
    if (await _mesh.usbLog(text)) {
      toast(t('logSent'));
      return;
    }
    try {
      final r = await api.sendDevLog(_devLogRecipient, text);
      toast(t(r.ok ? 'logSent' : 'logNotSent'));
    } catch (_) {
      toast(t('logNotSent'));
    }
  }

  void _aboutTap() {
    _devTaps++;
    _devTimer?.cancel();
    _devTimer = Timer(const Duration(seconds: 2), () => _devTaps = 0);
    if (_devTaps < 5) return;
    _devTaps = 0;
    final on = !_state.settings.dev;
    api.saveSettings({'dev': on});
    toast(t(on ? 'devOn' : 'devOff'));
    if (on) _loadDev();
  }

  Future<void> _loadDev() async {
    final tr = await _mesh.getTransports();
    final caps = await _mesh.getBleCaps();
    final native = await _mesh.getDiag();
    if (!mounted) return;
    setState(() {
      _devTransports = tr;
      _bleCaps = caps;
      _devLog =
          '${native.isNotEmpty ? '$native\n--- JS ---\n' : ''}${diagText()}';
    });
  }

  String _specOf(Neighbor n) => _forceSpec[n.node] ?? 'lan';

  Future<void> _forceConnect(Neighbor n) async {
    final ok = await _mesh.devConnect(n.node, _specOf(n));
    toast(t(ok ? 'devStarted' : 'devNotStarted'));
    unawaited(Future.delayed(const Duration(milliseconds: 1500), _loadDev));
  }

  Future<void> _forceClose(Neighbor n) async {
    await _mesh.devDisconnect(n.node, _specOf(n).split(':').first);
    unawaited(Future.delayed(const Duration(milliseconds: 500), _loadDev));
  }

  Future<void> _clearDev() async {
    await _mesh.clearDiag();
    diagClear();
    await _loadDev();
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      toast(t('copiedLog'));
    } catch (_) {
      toast(t('err_bad_link'));
    }
  }

  Future<void> _toggleNet(Neighbor n) async {
    if (_openNode == n.node) {
      setState(() => _openNode = null);
      return;
    }
    setState(() => _openNode = n.node);
    Map? fresh;
    try {
      for (final x in await _mesh.getNeighbors()) {
        if (x['node'] == n.node) {
          fresh = x;
          break;
        }
      }
    } catch (_) {}
    var links = _links(fresh?['links']);
    if (links.isEmpty) links = _links(n['links']);
    if (links.isEmpty) links = [n];
    final card = n['card'];
    final detail = [
      'node ${n.node}',
      'card ${card is Map ? '${card['id']} (${card['name']})' : 'none'}',
      'unsupported ${js.truthy(n['unsupported'])}',
      for (final l in links)
        '${_linkLabel(l)} ${_num(l['kbps'])} kbps${js.truthy(l['rttMs']) ? ' rtt ${_num(l['rttMs'])} ms' : ''}${l['outbound'] == null
            ? ''
            : js.truthy(l['outbound'])
            ? ' out'
            : ' in'}',
    ];
    debugPrint('ripplo net ${jsonEncode(detail)}');
    if (mounted) setState(() => _detail = detail);
  }

  Future<void> _saveName() async {
    try {
      await api.setName(_draft ?? '');
      if (mounted) setState(() => _draft = null);
    } catch (e) {
      toast(t('err_${e is RipploError ? e.code : 'bad_name'}'));
    }
  }

  Future<void> _pickPhoto() async {
    final pick = widget.onPickAvatar;
    if (pick == null) return;
    try {
      final r = await pick();
      if (r != null) await api.setAvatar(r);
    } catch (_) {
      toast(t('err_bad_avatar'));
    }
  }

  Future<void> _customColor() async {
    final pick = widget.onPickColor ?? (cur) => _pickHex(context, cur);
    final hex = await pick(widget.theme.accent);
    if (hex != null && _hex6.hasMatch(hex)) widget.theme.setAccent(hex);
  }

  Widget _twoLine(
    BuildContext context,
    String label,
    String hint, {
    Color? color,
  }) => Expanded(
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label, style: rs(context, RipploText.rowLabel, color)),
          const TextSpan(text: '\n'),
          TextSpan(
            text: hint,
            style: rs(context, RipploText.rowHint, context.rc.text2),
          ),
        ],
      ),
      strutStyle: _strut,
    ),
  );

  Widget _sm(String text, VoidCallback? onTap, {bool ghost = false}) =>
      IntrinsicWidth(
        child: RBtn(
          text: text,
          sm: true,
          kind: ghost ? RBtnKind.ghost : RBtnKind.primary,
          onTap: onTap,
        ),
      );

  Widget _acts(List<Widget> kids) => Expanded(
    child: Wrap(
      alignment: WrapAlignment.end,
      spacing: kRowGap,
      runSpacing: kRowGap,
      children: kids,
    ),
  );

  Widget _hintRow(String text) =>
      RRow(children: [Expanded(child: RHint(text))]);

  Widget _toggle(
    String label,
    String hint,
    bool value,
    ValueChanged<bool> on,
  ) => RRow(
    children: [
      _twoLine(context, label, hint),
      RSwitch(value: value, onChanged: on, label: label),
    ],
  );

  Widget _profile(RipploState s) {
    final p = s.profile;
    final c = context.rc;
    final hasPhoto = (p?.avatar ?? '').isNotEmpty;
    return RCard(
      children: [
        RRow(
          crossAxis: CrossAxisAlignment.start,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Pressable(
                  label: t('changePhoto'),
                  onTap: _pickPhoto,
                  builder: (_, _) =>
                      Avatar(name: p?.name, photo: p?.avatar, size: 44),
                ),
                if (hasPhoto && _draft == null) ...[
                  const SizedBox(height: 6),
                  _sm(t('removePhoto'), () => api.setAvatar(''), ghost: true),
                ],
              ],
            ),
            Expanded(
              child: _draft == null
                  ? Pressable(
                      label: t('changeName'),
                      onTap: () => setState(() {
                        _draft = p?.name ?? '';
                        _draftCtl.text = _draft!;
                      }),
                      builder: (_, _) => SizedBox(
                        height: 44,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 18,
                              child: Text(
                                p?.name ?? '',
                                style: rs(
                                  context,
                                  RipploText.rowLabel.copyWith(height: 1.2),
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            SizedBox(
                              height: 15.6,
                              child: Text(
                                p?.ripploId ?? '',
                                style: monoStyle(
                                  context,
                                  RipploText.rowHint.copyWith(height: 1.2),
                                  c.text2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RField(
                      controller: _draftCtl,
                      maxLength: 40,
                      label: t('yourName'),
                      onChanged: (v) => _draft = v,
                      onSubmitted: (_) => _saveName(),
                    ),
            ),
          ],
        ),
        if (_draft != null)
          RRow(
            children: [
              _acts([
                _sm(
                  t('cancel'),
                  () => setState(() => _draft = null),
                  ghost: true,
                ),
                _sm(t('save'), _saveName),
              ]),
            ],
          ),
        _hintRow(t('photoHint')),
        _toggle(
          t('discoverable'),
          t('discoverableHint'),
          !s.settings.hidden,
          (_) => api.saveSettings({'hidden': !s.settings.hidden}),
        ),
        RRow(
          onTap: widget.onMyCode ?? () => ui.add = const AddRequest(),
          children: [
            Lucide(LucideIcons.qrCode, size: 22, strokeWidth: 1.75),
            Expanded(child: RLabel(t('myCode'))),
          ],
        ),
      ],
    );
  }

  Widget _appearance() {
    final th = widget.theme;
    final custom = !kAccents.contains(th.accent);
    return RCard(
      pad: true,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped(
            [
              RSeg<String>(
                options: [
                  for (final m in const ['system', 'dark', 'light'])
                    (m, t('mode_$m')),
                ],
                value: th.mode,
                onChanged: th.setMode,
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RHint(t('accent')),
                  RSwatches(
                    children: [
                      for (final a in kAccents)
                        RSwatch(
                          color: hexColor(a),
                          label: a,
                          selected: th.accent == a,
                          onTap: () => th.setAccent(a),
                        ),
                      RSwatch(
                        kind: RSwatchKind.rainbow,
                        label: t('customColor'),
                        selected: custom,
                        onTap: _customColor,
                      ),
                    ],
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RHint(t('background')),
                  RSwatches(
                    children: [
                      for (final g in kGradients)
                        g.isEmpty
                            ? RSwatch(
                                kind: RSwatchKind.none,
                                label: t('none'),
                                selected: th.gradient == g,
                                onTap: () => th.setGradient(g),
                              )
                            : RSwatch(
                                color: hexColor(g),
                                label: g,
                                selected: th.gradient == g,
                                onTap: () => th.setGradient(g),
                              ),
                    ],
                  ),
                ],
              ),
              RSeg<String>(
                options: const [('en', 'English'), ('pl', 'Polski')],
                value: locale.value,
                onChanged: setLocale,
              ),
            ],
            16,
            vertical: true,
          ),
        ),
      ],
    );
  }

  Widget _network(RipploState s) {
    final c = context.rc;
    return RCard(
      children: [
        if (s.neighbors.isEmpty) _hintRow(t('noNeighbors')),
        for (final n in s.neighbors) ...[
          RRow(
            onTap: () => _toggleNet(n),
            children: [
              _twoLine(
                context,
                _nodeName(n),
                '${{
                  for (final l in _links(n['links']).isEmpty ? [n] : _links(n['links'])) _linkLabel(l),
                }.join(' + ')} · ${_kbps(n)}',
              ),
              if (js.truthy(n['unsupported']))
                RChip(t('updateNeeded'))
              else
                RChip(t('connected'), kind: RChipKind.ok),
            ],
          ),
          if (_openNode == n.node)
            RRow(
              children: [
                Expanded(
                  child: Text(
                    _detail.join('\n'),
                    style: monoStyle(context, RipploText.rowHint, c.text2),
                  ),
                ),
              ],
            ),
        ],
        _toggle(
          t('backgroundRelay'),
          t('relayHint'),
          s.settings.backgroundRelay,
          (_) => api.saveSettings({
            'backgroundRelay': !s.settings.backgroundRelay,
          }),
        ),
      ],
    );
  }

  Widget _security(RipploState s) {
    final c = context.rc;
    final (icon, hint) = switch (s.integrity.status) {
      'ok' => (LucideIcons.shieldCheck, 'integrityOk'),
      'mismatch' => (LucideIcons.shieldAlert, 'integrityBad'),
      _ => (LucideIcons.shieldQuestion, 'integrityUnknown'),
    };
    return RCard(
      children: [
        if (s.devCrypto) RDevWarnRow(t('devCryptoWarn')),
        RRow(
          children: [
            Lucide(icon, size: 22, strokeWidth: 1.75),
            _twoLine(context, t('integrity'), t(hint)),
          ],
        ),
        RRow(
          color: s.insecureStorage ? c.warn : null,
          children: [
            if (s.insecureStorage)
              Lucide(LucideIcons.triangleAlert, size: 22)
            else
              Lucide(LucideIcons.shieldCheck, size: 22, strokeWidth: 1.75),
            _twoLine(
              context,
              t('dbEncryption'),
              t(s.insecureStorage ? 'dbInsecure' : 'dbSecure'),
              color: s.insecureStorage ? c.warn : null,
            ),
          ],
        ),
        RRow(
          children: [
            Lucide(LucideIcons.lock, size: 22, strokeWidth: 1.75),
            _twoLine(context, t('signal'), t('signalInfo')),
          ],
        ),
        if (_mesh.isNative)
          _toggle(
            t('appLock'),
            t('appLockHint'),
            s.settings.appLock,
            (v) => widget.onSetAppLock?.call(v),
          ),
      ],
    );
  }

  Widget _updates(RipploState s) {
    final u = s.update;
    final c = context.rc;
    final fromPlay = s.fromPlay;
    final progress = u.progress;
    return RCard(
      children: [
        RawGestureDetector(
          gestures: {
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: const Duration(seconds: 2),
                  ),
                  (r) => r.onLongPress = _sendLogs,
                ),
          },
          child: Semantics(
            tooltip: t('holdToSendLogs'),
            child: RRow(
              children: [
                Expanded(child: RLabel(t('currentVersion'))),
                RVal(u.current.isEmpty ? '–' : u.current),
              ],
            ),
          ),
        ),
        if (!fromPlay)
          RRow(
            children: [
              Expanded(child: RLabel(t('latestVersion'))),
              RVal((u.latest ?? '').isEmpty ? '–' : u.latest!),
            ],
          ),
        if (!fromPlay && js.truthy(u.error)) _hintRow(u.error!),
        if (!fromPlay && progress != null)
          RRow(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 16,
                    child: Stack(
                      children: [
                        ColoredBox(
                          color: c.surface2,
                          child: const SizedBox.expand(),
                        ),
                        FractionallySizedBox(
                          widthFactor: progress.toDouble().clamp(0, 1),
                          child: ColoredBox(
                            color: c.accent,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (!fromPlay)
          RRow(
            children: [
              _sm(
                t(u.checking ? 'checking' : 'checkNow'),
                u.checking ? null : () => widget.onCheckUpdate?.call(true),
              ),
              const Expanded(child: SizedBox()),
              if (u.available && _android && (u.apkUrl ?? '').isNotEmpty)
                _sm(
                  t('install'),
                  u.installing || u.checking
                      ? null
                      : () => widget.onInstall?.call(),
                )
              else if (u.available)
                _sm(t('openRelease'), () => _open(u.url ?? '')),
            ],
          ),
        if (_android && !fromPlay)
          _toggle2(
            t('autoUpdate'),
            s.settings.autoUpdate,
            (_) => api.saveSettings({'autoUpdate': !s.settings.autoUpdate}),
          ),
      ],
    );
  }

  Widget _toggle2(String label, bool value, ValueChanged<bool> on) => RRow(
    children: [
      Expanded(child: RLabel(label)),
      RSwitch(value: value, onChanged: on, label: label),
    ],
  );

  Widget _about(RipploState s) {
    final cur = s.update.current.isEmpty ? '–' : s.update.current;
    return RCard(
      children: [
        RRow(
          onTap: _aboutTap,
          children: [_twoLine(context, 'Ripplo', t('tagline')), RVal(cur)],
        ),
        RRow(
          onTap: () => _open(_repo),
          children: [
            const Expanded(child: RLabel('GitHub')),
            Lucide(LucideIcons.externalLink, size: 18),
          ],
        ),
        RRow(
          children: [
            Expanded(child: RLabel(t('license'))),
            const RVal('AGPL-3.0'),
          ],
        ),
      ],
    );
  }

  Widget _scrollBox(double max, Widget child) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: max),
    child: SingleChildScrollView(child: child),
  );

  Widget _developer(RipploState s) {
    final c = context.rc;
    final mono11 = RipploText.rowHint.copyWith(fontSize: 11);
    final openLog = [
      for (final l in s.devLogs)
        if (l.id == _openId) l,
    ].firstOrNull;
    final caps = _bleCaps.coded && _bleCaps.extended;
    return RCard(
      children: [
        for (final x in _devTransports)
          RRow(
            children: [
              Expanded(child: RLabel('${x['name']}')),
              RChip(
                js.truthy(x['running'])
                    ? 'running'
                    : js.truthy(x['unsupported'])
                    ? 'unsupported'
                    : 'stopped',
                kind: js.truthy(x['running'])
                    ? RChipKind.ok
                    : js.truthy(x['unsupported'])
                    ? RChipKind.bad
                    : RChipKind.warn,
              ),
            ],
          ),
        RRow(
          children: [
            const Expanded(child: RLabel('ble coded')),
            RChip(
              caps ? 'supported' : 'unsupported',
              kind: caps ? RChipKind.ok : RChipKind.bad,
            ),
          ],
        ),
        _hintRow(t('devStageTitle')),
        if (_stageLog.isNotEmpty)
          _scrollBox(
            340,
            RRows(
              children: [
                for (final e in _stageLog)
                  RRow(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            style: monoStyle(
                              context,
                              mono11,
                              _stageColor(c, e['stage'] as String?),
                            ),
                            children: [
                              TextSpan(
                                text:
                                    '${e['time']} ${e['medium']} ${e['node']} ',
                              ),
                              TextSpan(
                                text: t('devStage_${e['stage']}'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(text: ' ${e['detail']}'),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          )
        else
          _hintRow('–'),
        _hintRow('${t('devLogsTitle')} (${s.devLogs.length})'),
        for (final l in s.devLogs)
          RRow(
            children: [
              _twoLine(
                context,
                l.name.isNotEmpty
                    ? l.name
                    : l.from.substring(0, l.from.length.clamp(0, 8)),
                '${localeDateTime(l.ts, 'en')} · ${(l.text.length / 1024).toStringAsFixed(1)} KB',
              ),
              _sm(
                t('devLogCopy'),
                () => _copy(
                  '${l.name.isNotEmpty ? l.name : l.from.substring(0, l.from.length.clamp(0, 8))} ${localeDateTime(l.ts, 'en')}\n${l.text}',
                ),
              ),
              _sm(
                t(_openId == l.id ? 'devLogClose' : 'devLogOpen'),
                () => setState(() => _openId = _openId == l.id ? null : l.id),
              ),
              _sm(t('devLogDelete'), () => api.deleteDevLog(l.id), ghost: true),
            ],
          ),
        if (openLog != null)
          RRow(
            children: [
              Expanded(
                child: _scrollBox(
                  280,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final ln in openLog.text.split('\n'))
                        Text(
                          ln,
                          style: rs(
                            context,
                            mono11.copyWith(fontFamily: debugFontFamily),
                            _lineColor(c, ln),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        _hintRow(t('devForce')),
        for (final n in s.neighbors)
          RRow(
            children: [
              Expanded(child: RLabel(_nodeName(n))),
              SizedBox(
                width: 120,
                child: _Select(
                  value: _specOf(n),
                  label: t('devForce'),
                  onChanged: (v) => setState(() => _forceSpec[n.node] = v),
                ),
              ),
              _sm(t('devConnectBtn'), () => _forceConnect(n)),
              _sm(t('devClose'), () => _forceClose(n), ghost: true),
            ],
          ),
        RRow(
          children: [
            Expanded(
              child: _scrollBox(
                280,
                Text(
                  _devLog.isEmpty ? '–' : _devLog,
                  style: monoStyle(context, mono11, c.text2),
                ),
              ),
            ),
          ],
        ),
        RRow(
          children: [
            _acts([
              _sm(t('refresh'), _loadDev, ghost: true),
              _sm(t('copyLog'), () => _copy(_devLog), ghost: true),
              _sm(t('clearLog'), _clearDev, ghost: true),
            ]),
          ],
        ),
      ],
    );
  }

  Widget _contributor(String login) {
    final c = context.rc;
    final ini = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.surface2, shape: BoxShape.circle),
      child: Text(
        settingsInitials(login),
        style: rs(
          context,
          RipploText.body.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open('https://github.com/$login'),
      child: RCard(
        pad: true,
        children: [
          Row(
            children: gapped([
              _broken[login] == true
                  ? ini
                  : ClipOval(
                      child: Image.network(
                        'https://github.com/$login.png?size=96',
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && _broken[login] != true) {
                              setState(() => _broken[login] = true);
                            }
                          });
                          return ini;
                        },
                      ),
                    ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: login,
                        style: rs(
                          context,
                          RipploText.body.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const TextSpan(text: '\n'),
                      TextSpan(
                        text: t('githubProfile'),
                        style: rs(context, RipploText.rowHint, c.text2),
                      ),
                    ],
                  ),
                  strutStyle: _strut,
                ),
              ),
              Lucide(LucideIcons.externalLink, size: 18, color: c.text),
            ], 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, locale, widget.theme]),
    builder: (context, _) {
      final s = _state;
      return RPage(
        controller: widget.controller,
        children: [
          RHdr(children: [RHdrTitle(t('settings'))]),
          RSection(t('profile')),
          _profile(s),
          RSection(t('appearance')),
          _appearance(),
          RSection(t('network')),
          _network(s),
          RSection(t('security')),
          _security(s),
          BackupCard(mesh: widget.mesh, backupMeta: widget.backupMeta),
          RSection(t('updates')),
          _updates(s),
          RSection(t('about')),
          _about(s),
          if (s.settings.dev) ...[RSection(t('developer')), _developer(s)],
          RSection(t('contributors')),
          for (final c in contributors) _contributor(c['login']!),
        ],
      );
    },
  );
}

class _Select extends StatelessWidget {
  const _Select({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return PopupMenuButton<String>(
      tooltip: label,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final s in _specs)
          PopupMenuItem(value: s, child: Text(_specNames[s]!)),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: kFieldMin),
        padding: const EdgeInsets.symmetric(horizontal: kFieldPadX),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border, width: kBorderWidth),
          borderRadius: BorderRadius.circular(kRadiusField),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _specNames[value]!,
                style: rs(context, RipploText.body),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            CustomPaint(size: const Size(10, 6), painter: _Chevron(c.text)),
          ],
        ),
      ),
    );
  }
}

class _Chevron extends CustomPainter {
  _Chevron(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );

  @override
  bool shouldRepaint(_Chevron old) => old.color != color;
}

Future<String?> _pickHex(BuildContext context, String current) {
  final ctl = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: ctx.rc.bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped(
            [
              RField(
                controller: ctl,
                maxLength: 7,
                label: t('customColor'),
                onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
              ),
              RBtn(
                text: t('save'),
                block: true,
                onTap: () => Navigator.pop(ctx, ctl.text.trim()),
              ),
            ],
            12,
            vertical: true,
          ),
        ),
      ),
    ),
  );
}
