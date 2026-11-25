import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/app_instances.dart' as api;
import '../../core/app_state.dart';
import '../../translations.dart';
import '../../mesh/native_mesh_bridge.dart';
import '../shared_widgets.dart';
import 'app_icon.dart';
import '../../util/js_compat.dart' as js;

class CallOverlay extends StatefulWidget {
  const CallOverlay({super.key, this.state, this.onRing, this.onKeepAwake});

  final RipploState? state;
  final ValueChanged<bool>? onRing;
  final ValueChanged<bool>? onKeepAwake;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  Timer? _tick;
  int _now = js.now();
  bool? _ringing;
  bool? _awake;

  RipploState get _state => widget.state ?? api.state;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = js.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ring(false);
    _awake = null;
    _keepAwake(false);
    super.dispose();
  }

  void _ring(bool on) {
    if (_ringing == on) return;
    _ringing = on;
    final f = widget.onRing;
    if (f != null) {
      f(on);
    } else {
      js.fire(on ? mesh.startRing() : mesh.stopRing());
    }
  }

  void _keepAwake(bool on) {
    if (_awake == on) return;
    _awake = on;
    final f = widget.onKeepAwake;
    if (f != null) {
      f(on);
    } else {
      js.fire(mesh.keepAwake(on));
    }
  }

  String _clock(CallInfo c) {
    final s = c.startedAt == 0
        ? 0
        : ((_now - c.startedAt) / 1000).floor().clamp(0, 1 << 40);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String _status(CallInfo c) {
    if (c.status == 'ended') return t('call_${c.reason}');
    if (c.status == 'active') return _clock(c);
    if (c.status == 'connecting') return t('callConnecting');
    return t(c.dir == 'in' ? 'incomingCall' : 'calling');
  }

  Widget _round(
    BuildContext context, {
    required LucideData icon,
    required double size,
    required Color bg,
    required Color fg,
    required String label,
    required VoidCallback onTap,
    bool? toggled,
  }) => Pressable(
    onTap: onTap,
    label: label,
    toggled: toggled,
    radius: 34,
    builder: (_, _) => Container(
      width: 68,
      height: 68,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Lucide(icon, size: size, color: fg),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, locale]),
    builder: (context, _) {
      final c = _state.call;
      _keepAwake(c != null && c.status != 'ended');
      final incoming = c != null && c.status == 'ringing' && c.dir == 'in';
      _ring(incoming);
      if (c == null) return const SizedBox.shrink();
      final peer = _state.contact(c.peer);
      final rc = context.rc;
      final pad = MediaQuery.paddingOf(context);
      final body = RipploText.body;
      final grey = rs(context, body.copyWith(fontSize: 16), rc.text2);
      final stats = c.stats;
      final warn = c.warn;
      return Semantics(
        container: true,
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: peer?.name,
        child: ColoredBox(
          color: rc.bg,
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, pad.top + 72, 24, pad.bottom + 56),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: gapped(
                      [
                        Avatar(
                          name: peer?.name,
                          photo: peer?.avatar,
                          size: 112,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            peer?.name ?? '',
                            textAlign: TextAlign.center,
                            style: rs(
                              context,
                              RipploText.h1.copyWith(fontSize: 26),
                            ),
                          ),
                        ),
                        Semantics(
                          liveRegion: true,
                          child: Nudge(
                            -1,
                            child: Text(_status(c), style: grey),
                          ),
                        ),
                        if (warn != null && warn != false && warn != '')
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 290),
                            child: Text(
                              t('callWarn_$warn'),
                              textAlign: TextAlign.center,
                              style: grey.copyWith(letterSpacing: -.04),
                            ),
                          ),
                        if (c.status == 'active' && stats != null)
                          SizedBox(
                            width: double.infinity,
                            child: Text(
                              t('callStats', {
                                ...stats,
                              }).replaceAll(RegExp(r' {2,}'), ' '),
                              textAlign: TextAlign.left,
                              style: rs(
                                context,
                                body.copyWith(
                                  fontSize: 12,
                                  letterSpacing: -.03,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                                rc.text2,
                              ),
                            ),
                          ),
                      ],
                      8,
                      vertical: true,
                    ),
                  ),
                ),
                if (c.status != 'ended')
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: gapped(
                      incoming
                          ? [
                              _round(
                                context,
                                icon: LucideIcons.phoneOff,
                                size: 28,
                                bg: rc.danger,
                                fg: const Color(0xFFFFFFFF),
                                label: t('callDecline'),
                                onTap: () => api.hangUp(),
                              ),
                              _round(
                                context,
                                icon: LucideIcons.phone,
                                size: 28,
                                bg: rc.ok,
                                fg: const Color(0xFFFFFFFF),
                                label: t('callAnswer'),
                                onTap: () => api.acceptCall(),
                              ),
                            ]
                          : [
                              _round(
                                context,
                                icon: c.muted
                                    ? LucideIcons.micOff
                                    : LucideIcons.mic,
                                size: 26,
                                bg: c.muted ? rc.text : rc.surface2,
                                fg: c.muted ? rc.bg : rc.text,
                                label: t(c.muted ? 'callUnmute' : 'callMute'),
                                toggled: c.muted,
                                onTap: () => api.setMuted(!c.muted),
                              ),
                              _round(
                                context,
                                icon: LucideIcons.phoneOff,
                                size: 28,
                                bg: rc.danger,
                                fg: const Color(0xFFFFFFFF),
                                label: t('callEnd'),
                                onTap: () => api.hangUp(),
                              ),
                            ],
                      40,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
