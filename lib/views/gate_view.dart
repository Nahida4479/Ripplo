import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../components/brand.dart';
import '../i18n.dart';
import '../mesh/bridge.dart';
import '../services/permissions.dart';
import '../ui/widgets.dart';
import '../util/js.dart' as js;

const _asked = 'ripplo.optionalAsked';

const _all = <(String, LucideData, String)>[
  ('bluetooth', LucideIcons.bluetooth, 'permBluetooth'),
  ('wifi', LucideIcons.wifi, 'permWifi'),
  ('notifications', LucideIcons.bell, 'permNotifications'),
  ('microphone', LucideIcons.mic, 'permMicrophone'),
  ('fullscreen', LucideIcons.phoneIncoming, 'permFullScreen'),
];

bool _optionalMissing(Map<String, String> p) => [
  'microphone',
  'fullscreen',
  'battery',
].any((k) => p[k] != null && p[k] != 'granted');

Future<bool> _wasAsked() async {
  try {
    return (await SharedPreferences.getInstance()).getString(_asked) == '1';
  } catch (_) {
    return false;
  }
}

Future<void> _markAsked() async {
  try {
    await (await SharedPreferences.getInstance()).setString(_asked, '1');
  } catch (_) {}
}

class GateView extends StatefulWidget {
  const GateView({
    super.key,
    this.onGranted,
    this.check,
    this.request,
    this.requestBattery,
    this.requestFullScreen,
  });

  final VoidCallback? onGranted;
  final Future<Map<String, String>> Function()? check;
  final Future<Map<String, String>> Function()? request;
  final Future<void> Function()? requestBattery;
  final Future<void> Function()? requestFullScreen;

  @override
  State<GateView> createState() => _GateViewState();
}

class _GateViewState extends State<GateView> {
  Map<String, String> _perms = const {};

  Future<Map<String, String>> _check() =>
      (widget.check ?? () => checkPermissions(mesh))();

  Future<void> _battery() =>
      (widget.requestBattery ?? mesh.requestBatteryExemption)();

  @override
  void initState() {
    super.initState();
    js.fire(_check().then((p) => _apply(p, false)));
  }

  Future<void> _apply(Map<String, String> p, bool force) async {
    if (!mounted) return;
    setState(() => _perms = p);
    if (allGranted(p) && (force || !_optionalMissing(p) || await _wasAsked())) {
      widget.onGranted?.call();
    }
  }

  Future<void> _grant() async {
    final p = await (widget.request ?? () => requestPermissions(mesh))();
    if (p['battery'] == 'prompt') await _battery();
    if (p['fullscreen'] == 'prompt') {
      await (widget.requestFullScreen ?? mesh.requestFullScreen)();
    }
    await _markAsked();
    await _apply(
      p['battery'] == 'prompt' || p['fullscreen'] == 'prompt'
          ? await _check()
          : p,
      true,
    );
  }

  Future<void> _skip() async {
    await _markAsked();
    widget.onGranted?.call();
  }

  RChipKind _kind(String? v) => v == 'granted'
      ? RChipKind.ok
      : v == 'denied'
      ? RChipKind.bad
      : RChipKind.plain;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: locale,
    builder: (context, _) {
      final c = context.rc;
      final rows = [
        for (final (k, icon, label) in _all)
          if (!const ['microphone', 'fullscreen'].contains(k) ||
              _perms[k] != null)
            RRow(
              children: [
                Lucide(icon, size: 22, strokeWidth: 1.75),
                Expanded(child: Nudge(-1, child: RLabel(t(label)))),
                Nudge(
                  -1,
                  child: RChip(
                    t('perm_${_perms[k] ?? 'prompt'}'),
                    kind: _kind(_perms[k]),
                    icon: _perms[k] == 'granted' ? LucideIcons.check : null,
                  ),
                ),
              ],
            ),
      ];
      final battery = _perms['battery'];
      return ScrollCenter(
        children: [
          const AppIcon(),
          Nudge(-1, child: Text('Ripplo', style: brandH1(context))),
          Nudge(-1, child: RCenterText(t('gateWhy'))),
          Narrow(
            child: Padding(
              padding: const EdgeInsets.only(bottom: kCardMarginBottom),
              child: RCard(
                marginBottom: 0,
                children: [
                  ...rows,
                  RRow(
                    onTap: () => js.fire(_battery()),
                    children: [
                      Lucide(
                        LucideIcons.batteryCharging,
                        size: 22,
                        strokeWidth: 1.75,
                      ),
                      Expanded(
                        child: Nudge(
                          1,
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: t('allowBackground'),
                                  style: rs(context, RipploText.rowLabel),
                                ),
                                const TextSpan(text: '\n'),
                                TextSpan(
                                  text: t('optional'),
                                  style: rs(
                                    context,
                                    RipploText.rowHint,
                                    c.text2,
                                  ),
                                ),
                              ],
                            ),
                            textAlign: TextAlign.left,
                            strutStyle: const StrutStyle(
                              fontSize: 15,
                              height: 1.4,
                              forceStrutHeight: true,
                              leadingDistribution: TextLeadingDistribution.even,
                            ),
                          ),
                        ),
                      ),
                      if (battery != null)
                        RChip(
                          t('perm_$battery'),
                          kind: battery == 'granted'
                              ? RChipKind.ok
                              : RChipKind.plain,
                          icon: battery == 'granted' ? LucideIcons.check : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Narrow(
            child: RBtn(text: t('grantPermissions'), onTap: _grant),
          ),
          if (allGranted(_perms))
            Narrow(
              child: RBtn(
                text: t('notNow'),
                kind: RBtnKind.ghost,
                onTap: _skip,
              ),
            ),
        ],
      );
    },
  );
}
