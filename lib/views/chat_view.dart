import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../core/api.dart' as api;
import '../core/state.dart';
import '../crypto/identity.dart';
import '../i18n.dart';
import '../services/media_files.dart';
import '../ui/ui_state.dart';
import '../ui/widgets.dart';
import '../util/js.dart' as js;
import '../util/link_label.dart';

const TextLeadingDistribution _even = TextLeadingDistribution.even;
const int _maxStaged = 10;
const int _waveBars = 40;
const double _swipe = 56;

Widget _u(double dy, Widget w) =>
    Transform.translate(offset: Offset(0, -dy), child: w);

TextStyle _s(
  BuildContext cx,
  double size,
  Color color, {
  FontWeight? w,
  double h = 1.4,
}) => rs(
  cx,
  TextStyle(
    fontSize: size,
    height: h,
    fontWeight: w,
    leadingDistribution: _even,
  ),
  color,
);

const List<String> _enDays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const List<String> _enMonths = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const List<String> _plDays = [
  'poniedziałek',
  'wtorek',
  'środa',
  'czwartek',
  'piątek',
  'sobota',
  'niedziela',
];
const List<String> _plMonths = [
  'stycznia',
  'lutego',
  'marca',
  'kwietnia',
  'maja',
  'czerwca',
  'lipca',
  'sierpnia',
  'września',
  'października',
  'listopada',
  'grudnia',
];

String _p2(int n) => n.toString().padLeft(2, '0');

String dayLabel(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return locale.value == 'pl'
      ? '${_plDays[d.weekday - 1]}, ${d.day} ${_plMonths[d.month - 1]}'
      : '${_enDays[d.weekday - 1]}, ${_enMonths[d.month - 1]} ${d.day}';
}

String timeLabel(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  if (locale.value == 'pl') return '${_p2(d.hour)}:${_p2(d.minute)}';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${_p2(h)}:${_p2(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
}

bool _sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a);
  final y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String dur(num? s) {
  final v = s ?? 0;
  return '${(v / 60).floor()}:${_p2((v % 60).round())}';
}

List<double> voiceBars(Msg m) {
  final wave = m.att?.wave;
  if (wave != null && wave.isNotEmpty) {
    return [
      for (final v in wave) 4 + ((v as num) / 255 * 22).round().toDouble(),
    ];
  }
  final units = m.id.codeUnits;
  return [
    for (var i = 0; i < units.length; i++)
      6 + ((units[i] * (i + 3)) % 18).toDouble(),
  ].take(28).toList();
}

({double? peak, List<int>? wave}) summarizeSamples(List<double> samples) {
  if (samples.isEmpty) return (peak: null, wave: null);
  final peak = samples.reduce(math.max);
  final size = samples.length / _waveBars;
  final step = math.max(size, 1);
  final wave = List<int>.generate(math.min(_waveBars, samples.length), (i) {
    final start = (i * step).floor();
    final end = math.min(
      math.max(((i + 1) * step).floor(), start + 1),
      samples.length,
    );
    final part = samples.sublist(start, end);
    return (part.reduce(math.max) / (peak == 0 ? 1 : peak) * 255).round();
  });
  return (peak: peak, wave: wave);
}

class StagedMedia {
  StagedMedia({this.bytes, this.path, required this.kind, required this.type});

  final Uint8List? bytes;
  final String? path;
  final String kind;
  final String type;

  Future<Uint8List> read() async => bytes ?? await File(path!).readAsBytes();
}

class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.id,
    this.state,
    this.onBack,
    this.onOpenContact,
    this.live = true,
    this.initialText = '',
    this.typingFreeze,
  });

  final String id;
  final RipploState? state;
  final VoidCallback? onBack;
  final void Function(String id)? onOpenContact;
  final bool live;
  final String initialText;
  final Duration? typingFreeze;

  @override
  State<ChatView> createState() => ChatViewState();
}

class SwipeDrag {
  SwipeDrag(this.m, this.x, this.y);

  final Msg m;
  final double x;
  final double y;
  bool locked = false;
  Timer? press;
}

class ChatViewState extends State<ChatView> {
  late final RipploState st = widget.state ?? api.state;
  final TextEditingController text = TextEditingController();
  final FocusNode focus = FocusNode();
  final ScrollController scroll = ScrollController();
  final Map<String, GlobalKey> keys = {};
  final ImagePicker picker = ImagePicker();

  Msg? replyTo;
  List<StagedMedia> staged = [];
  Msg? viewer;
  String? shown;
  String? flashId;
  int flashSeq = 0;
  String? playing;
  AudioPlayer? audio;
  String? audioFile;

  SwipeDrag? drag;
  bool swiped = false;
  String? offsetId;
  double offsetX = 0;
  bool offsetRest = true;

  bool rec = false;
  int recSec = 0;
  List<int> liveBars = [];
  final List<double> samples = [];
  AudioRecorder? recorder;
  String? recPath;
  int startedAt = 0;
  Timer? tick;
  StreamSubscription<Amplitude>? amp;

  int lastLen = 0;
  int lastTypers = 0;

  String get id => widget.id;
  Chat? get chat {
    for (final c in st.chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  Contact? get contact => st.contact(id);
  bool get isGroup => chat?.type == 'group';
  String get name {
    final a = chat?.name ?? '';
    return a.isNotEmpty ? a : (contact?.name ?? '');
  }

  bool get mediaLocked {
    final c = contact;
    return !isGroup && c != null && c.addedVia != 'incoming' && !c.cardAck;
  }

  bool get canCall {
    final c = contact;
    return !isGroup &&
        c != null &&
        !js.truthy(c.request) &&
        (c.addedVia != 'incoming' || js.truthy(c.cardSent));
  }

  List<Msg> get msgs => st.msgs(id) ?? const <Msg>[];
  List<Object?> get typers => (st.typing[id] as List<Object?>?) ?? const [];

  @override
  void initState() {
    super.initState();
    text.text = widget.initialText;
    text.addListener(_onText);
    st.addListener(_onState);
    locale.addListener(_onState);
    lastLen = msgs.length;
    lastTypers = typers.length;
    _toBottom();
    if (widget.live) {
      fire(_open());
    }
  }

  void fire(Future<void> f) => js.fire(f);

  Future<void> _open() async {
    await api.loadMessages(id);
    api.markRead(id);
    _toBottom();
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  void _onState() {
    if (!mounted) return;
    final n = msgs.length;
    final k = typers.length;
    if (n != lastLen) {
      lastLen = n;
      _toBottom();
      if (widget.live) api.markRead(id);
    }
    if (k != lastTypers) {
      if (k > lastTypers) _toBottom();
      lastTypers = k;
    }
    setState(() {});
  }

  bool pinned = true;
  double lastViewport = 0;
  double lastExtent = 0;

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification || n is ScrollEndNotification)
      pinned = n.metrics.extentAfter < 2;
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    final m = n.metrics;
    if (pinned &&
        m.viewportDimension == lastViewport &&
        m.maxScrollExtent > lastExtent + .5)
      _jump();
    lastViewport = m.viewportDimension;
    lastExtent = m.maxScrollExtent;
    return false;
  }

  void _jump() {
    if (mounted && scroll.hasClients)
      scroll.jumpTo(scroll.position.maxScrollExtent);
  }

  void _toBottom() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _jump())
      ..scheduleFrame();
  }

  @override
  void dispose() {
    st.removeListener(_onState);
    locale.removeListener(_onState);
    text.removeListener(_onText);
    text.dispose();
    focus.dispose();
    scroll.dispose();
    drag?.press?.cancel();
    tick?.cancel();
    amp?.cancel();
    final r = recorder;
    if (r != null) {
      fire(() async {
        try {
          await r.cancel();
        } catch (_) {}
        await r.dispose();
        await deleteMedia(recPath);
      }());
    }
    final a = audio;
    final f = audioFile;
    if (a != null) fire(a.dispose());
    fire(deleteMedia(f));
    super.dispose();
  }

  void replyToMessage(Msg m) => setState(() => replyTo = m);

  void stageMedia(List<StagedMedia> items) =>
      setState(() => staged = [...staged, ...items]);

  void fail(Object e) {
    if (e is RipploError) {
      toast(e.code == 'media_locked' ? t('err_media_locked') : e.message);
    } else {
      toast('$e');
    }
  }

  String? routeLine() {
    final cid = id;
    final c = contact;
    final known = c?['node'] as String?;
    final node = widget.live || c?.ik != null ? _safeNode(cid) : null;
    Neighbor? hit;
    for (final x in st.neighbors) {
      final card = x['card'];
      final xn = x['node'];
      if ((card is Map && card['id'] == cid) ||
          (node != null && xn == node) ||
          (known != null && xn == known)) {
        hit = x;
        break;
      }
    }
    if (hit != null) {
      final links = hit['links'];
      final list = links is List && links.isNotEmpty
          ? links.cast<Object?>()
          : <Object?>[hit];
      final out = <String>[];
      for (final l in list) {
        final s = isCodedLink(l)
            ? 'BLE Coded'
            : '${l is Map ? l['medium'] : null}'.toUpperCase();
        if (!out.contains(s)) out.add(s);
      }
      return out.join(' + ');
    }
    for (final p in st.people) {
      if (p.id == cid) {
        return js.now() - p.seenAt < 10 * 60000
            ? t('hops', {'n': p.hops})
            : null;
      }
    }
    return null;
  }

  String? _safeNode(String cid) {
    try {
      return api.nodeOf(cid);
    } catch (_) {
      return null;
    }
  }

  String subLine() {
    if (isGroup) return t('members', {'n': chat?.members?.length ?? 0});
    final c = contact;
    final ok = c != null && c.verification != 'none';
    return '${ok ? '✓ ${t('verified')}' : '⚠ ${t('notVerified')}'} · ${routeLine() ?? t('outOfRange')}';
  }

  String? get banner {
    final c = contact;
    if (isGroup || c == null) return null;
    if (c.conflict) return 'red';
    return c.verification == 'none' ? 'amber' : null;
  }

  Future<void> call() async {
    try {
      await api.startCall(id);
    } catch (e) {
      toast(t('err_${e is RipploError ? e.code : 'call_unsupported'}'));
    }
  }

  String authorOf(Msg m) => m.from == 'me'
      ? t('you')
      : (st.contact(m.from)?.name ?? '').ifEmpty('Ripplo');

  String whoName(Object? who) {
    if (who == st.profile?.ripploId) return t('you');
    return (st.contact('$who')?.name ?? '').ifEmpty('Ripplo');
  }

  String kindLabel(Object? kind) => t(
    kind == 'video'
        ? 'videoMessage'
        : kind == 'voice'
        ? 'voiceMessage'
        : 'photoMessage',
  );

  String snippet(Msg m) => (m.text ?? '').ifEmpty(kindLabel(m.att?.kind));

  String statusLabel(Msg m) {
    final hops = (m['hops'] as num?) ?? 0;
    return m.status == 'delivered' && hops > 1
        ? t('viaPhones', {'n': hops - 1})
        : t('status_${m.status}');
  }

  void confirmUnsend(Msg m) {
    ui.confirm = ConfirmRequest(
      title: t('unsendTitle'),
      text: t('unsendText'),
      ok: t('unsend'),
      danger: true,
      onOk: () async {
        try {
          await api.unsendMessage(id, m.id);
        } catch (e) {
          fail(e);
        }
      },
    );
  }

  void sure() {
    ui.confirm = ConfirmRequest(
      title: t('imSure'),
      text: t('imSureConfirm'),
      ok: t('confirm'),
      onOk: () => api.markVerified(id),
    );
  }

  Future<void> retryMesh() async {
    toast(await api.verifyNearby(id) ? t('verifiedOk') : t('verifyFailed'));
  }

  void onText(String v) {
    if (widget.live && v.trim().isNotEmpty) fire(api.sendTyping(id));
  }

  Future<void> send() async {
    final v = text.text.trim();
    if ((v.isEmpty && staged.isEmpty) || v.length > api.maxText) return;
    final items = staged;
    final to = replyTo?.id;
    setState(() {
      staged = [];
      replyTo = null;
      text.clear();
    });
    try {
      if (items.isEmpty) {
        await api.sendText(id, v, to);
        return;
      }
      for (var i = 0; i < items.length; i++) {
        final last = i == items.length - 1;
        final bytes = await items[i].read();
        await api.sendAttachment(
          id,
          (bytes: bytes, type: items[i].type, duration: null),
          items[i].kind,
          caption: last && v.isNotEmpty ? v : null,
          replyTo: i == 0 ? to : null,
        );
      }
    } catch (e) {
      fail(e);
    }
  }

  static const Map<String, String> _videoExt = {
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    '3gp': 'video/3gpp',
    'mkv': 'video/x-matroska',
    'm4v': 'video/mp4',
  };

  Future<void> pickFiles() async {
    if (mediaLocked) {
      toast(t('err_media_locked'));
      return;
    }
    List<XFile> files;
    try {
      files = await picker.pickMultipleMedia();
    } catch (_) {
      return;
    }
    final next = [...staged];
    for (final f in files) {
      if (next.length >= _maxStaged) break;
      if (await f.length() > api.maxFile) {
        toast(t('fileTooBig'));
        continue;
      }
      final ext = f.path.contains('.')
          ? f.path.split('.').last.toLowerCase()
          : '';
      final mime =
          f.mimeType ??
          _videoExt[ext] ??
          (ext == 'png' ? 'image/png' : 'image/jpeg');
      next.add(
        StagedMedia(
          path: f.path,
          kind: mime.startsWith('video') ? 'video' : 'image',
          type: mime,
        ),
      );
    }
    if (mounted) setState(() => staged = next);
  }

  void onDown(PointerDownEvent e, Msg m) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryButton)
      return;
    swiped = false;
    final d = SwipeDrag(m, e.position.dx, e.position.dy);
    drag = d;
    if (m.from == 'me') {
      d.press = Timer(const Duration(milliseconds: 550), () {
        if (identical(drag, d) && !d.locked) {
          swiped = true;
          drag = null;
          HapticFeedback.mediumImpact();
          confirmUnsend(m);
        }
      });
    }
  }

  void onMove(PointerMoveEvent e) {
    final d = drag;
    if (d == null) return;
    final dx = e.position.dx - d.x;
    final dy = e.position.dy - d.y;
    if (dx.abs() > 8 || dy.abs() > 8) d.press?.cancel();
    if (!d.locked) {
      if (dy.abs() > 12 && dy.abs() > dx.abs()) {
        drag = null;
        return;
      }
      if (dx.abs() < 12) return;
      d.locked = true;
    }
    setState(() {
      offsetId = d.m.id;
      offsetX = dx.clamp(-72, 72).toDouble();
      offsetRest = false;
    });
  }

  void endDrag(bool commit) {
    final d = drag;
    if (d == null) return;
    d.press?.cancel();
    final hit = d.locked && commit && offsetX.abs() >= _swipe;
    if (d.locked) {
      swiped = true;
      Timer(const Duration(milliseconds: 80), () => swiped = false);
    }
    if (hit) {
      HapticFeedback.lightImpact();
    }
    setState(() {
      if (hit) replyTo = d.m;
      offsetId = d.m.id;
      offsetX = 0;
      offsetRest = true;
    });
    drag = null;
  }

  void toggleStatus(Msg m) {
    if (!swiped) setState(() => shown = shown == m.id ? null : m.id);
  }

  void openImage(Msg m) {
    if (!swiped) setState(() => viewer = m);
  }

  void jump(Object? mid) {
    final cx = keys['$mid']?.currentContext;
    if (cx == null) return;
    Scrollable.ensureVisible(
      cx,
      alignment: .5,
      duration: const Duration(milliseconds: 300),
      curve: Curves.ease,
    );
    setState(() {
      flashId = '$mid';
      flashSeq++;
    });
    final seq = flashSeq;
    Timer(const Duration(milliseconds: 1200), () {
      if (mounted && flashSeq == seq) setState(() => flashId = null);
    });
  }

  Future<void> stopAudio() async {
    final a = audio;
    final f = audioFile;
    audio = null;
    audioFile = null;
    if (mounted && playing != null) setState(() => playing = null);
    try {
      await a?.dispose();
    } catch (_) {}
    await deleteMedia(f);
  }

  Future<void> play(Msg m) async {
    final was = playing;
    await stopAudio();
    if (was == m.id) return;
    final bytes = m.att?.bytes;
    if (bytes == null) {
      toast(t('playFailed'));
      return;
    }
    if (mounted) setState(() => playing = m.id);
    try {
      final path = await writeMedia(bytes, m.att!.mime);
      final p = AudioPlayer();
      audio = p;
      audioFile = path;
      await p.setFilePath(path);
      p.processingStateStream.listen((s) {
        if (s == ProcessingState.completed && identical(audio, p))
          fire(stopAudio());
      });
      await p.play();
    } catch (_) {
      await stopAudio();
      toast(t('playFailed'));
    }
  }

  Future<void> startRec() async {
    if (mediaLocked) {
      toast(t('err_media_locked'));
      return;
    }
    AudioRecorder? r;
    try {
      r = AudioRecorder();
      if (!await r.hasPermission()) {
        await r.dispose();
        toast(t('micDenied'));
        return;
      }
      final path = await newMediaPath('.m4a');
      await r.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      recorder = r;
      recPath = path;
      samples.clear();
      startedAt = js.now();
      amp = r.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) {
        final peak = a.current.isFinite
            ? math.pow(10, a.current / 20).toDouble().clamp(0.0, 1.0)
            : 0.0;
        samples.add(peak);
        if (!mounted) return;
        setState(() {
          liveBars = [...liveBars, 3 + (math.min(1, peak * 2.5) * 22).round()];
          if (liveBars.length > 32)
            liveBars = liveBars.sublist(liveBars.length - 32);
        });
      });
      tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => recSec++);
      });
      setState(() {
        rec = true;
        recSec = 0;
        liveBars = [];
      });
    } catch (_) {
      try {
        await r?.dispose();
      } catch (_) {}
      toast(t('micDenied'));
    }
  }

  Future<void> stopRec(bool cancel) async {
    tick?.cancel();
    await amp?.cancel();
    amp = null;
    if (mounted) setState(() => rec = false);
    final r = recorder;
    final planned = recPath;
    recorder = null;
    recPath = null;
    if (r == null) return;
    String? out;
    try {
      out = await r.stop();
    } catch (_) {}
    try {
      await r.dispose();
    } catch (_) {}
    out ??= planned;
    if (cancel || out == null) {
      await deleteMedia(out);
      return;
    }
    final seconds = math.max(1, ((js.now() - startedAt) / 1000).round());
    Uint8List bytes;
    try {
      bytes = await File(out).readAsBytes();
    } catch (_) {
      return;
    } finally {
      await deleteMedia(out);
    }
    final s = summarizeSamples(samples);
    if (bytes.length < 800 || (s.peak != null && s.peak! < 0.02)) {
      toast(t('noSound'));
      return;
    }
    if (bytes.length > api.maxFile) {
      toast(t('fileTooBig'));
      return;
    }
    try {
      await api.sendAttachment(
        id,
        (bytes: bytes, type: 'audio/mp4', duration: null),
        'voice',
        duration: seconds,
        wave: s.wave,
      );
    } catch (e) {
      fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final pad = MediaQuery.paddingOf(context);
    final page = RPage(
      full: true,
      children: [
        _header(context, c),
        if (banner != null) _banner(context, c, banner!),
        Expanded(child: _log(context, c)),
        if (replyTo != null) _replyBar(context, c),
        if (staged.isNotEmpty) _stagedRow(context, c),
        _composer(context, c),
      ],
    );
    return Stack(
      fit: StackFit.expand,
      children: [page, if (viewer != null) _viewer(context, pad)],
    );
  }

  Widget _header(BuildContext context, RipploColors c) {
    final who = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: isGroup ? null : () => widget.onOpenContact?.call(id),
      child: Semantics(
        button: true,
        enabled: !isGroup,
        label: t('contactInfo'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Avatar(
              name: name,
              photo: contact?.avatar,
              size: 38,
              group: isGroup,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _u(
                    1,
                    Text(
                      name,
                      style: _s(context, 15, c.text, w: FontWeight.w700),
                    ),
                  ),
                  Text(subLine(), style: _s(context, 12, c.text2, h: 1.75)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kHdrMin),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            RIconBtn(
              icon: LucideIcons.chevronLeft,
              size: 24,
              stroke: 2,
              label: t('back'),
              onTap: widget.onBack,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: who),
            ),
            if (canCall) ...[
              const SizedBox(width: 8),
              RIconBtn(
                icon: LucideIcons.phone,
                size: 22,
                stroke: 2,
                label: t('callAction'),
                onTap: st.call == null ? () => fire(call()) : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  double _w(String s, TextStyle st) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: st),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  Widget _banner(BuildContext context, RipploColors c, String kind) {
    final col = kind == 'red' ? c.danger : c.warn;
    final pv = contact?.peerVerified;
    final p = _s(context, 13, c.text);
    final btn = _s(context, 13, c.text, w: FontWeight.w600);
    final texts = [
      kind == 'red' ? t('conflictWarning') : t('unverifiedWarning'),
      if (pv != null)
        t('peerVerified', {
          'name': contact!.name,
          'method': t('method_${pv['level']}'),
        }),
    ];
    final labels = [
      t('verifyQr'),
      t('retryMesh'),
      if (kind == 'amber') t('imSure'),
    ];
    final double basis = math.max(
      texts.map((x) => _w(x, p)).reduce(math.max),
      labels.map((x) => 24 + _w(x, btn)).reduce((x, y) => x + y) +
          6 * (labels.length - 1),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: col.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(14),
          ),
          child: LayoutBuilder(
            builder: (context, bc) {
              final avail = bc.maxWidth - 10;
              final iconW = (20 * math.min(1.0, avail / (20 + basis)))
                  .toDouble();
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: iconW,
                    height: 20,
                    child: Center(
                      child: Lucide(
                        LucideIcons.shieldAlert,
                        size: iconW,
                        color: col,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final x in texts)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _FracText(x, p, 18.2, dy: -.5),
                          ),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            IntrinsicWidth(
                              child: RBtn(
                                text: labels[0],
                                sm: true,
                                kind: RBtnKind.ghost,
                                onTap: () =>
                                    ui.add = AddRequest(mode: 'verify', id: id),
                              ),
                            ),
                            IntrinsicWidth(
                              child: RBtn(
                                text: labels[1],
                                sm: true,
                                kind: RBtnKind.ghost,
                                onTap: () => fire(retryMesh()),
                              ),
                            ),
                            if (kind == 'amber')
                              IntrinsicWidth(
                                child: RBtn(
                                  text: labels[2],
                                  sm: true,
                                  kind: RBtnKind.ghost,
                                  onTap: sure,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _lockLine(BuildContext context, RipploColors c) {
    final dev = st.devCrypto;
    final color = dev ? c.danger : c.text2;
    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 17.8),
          child: Center(
            widthFactor: 1,
            child: _u(
              .5,
              Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: Lucide(
                        dev ? LucideIcons.shieldAlert : LucideIcons.lock,
                        size: 13,
                        color: color,
                      ),
                    ),
                    TextSpan(
                      text: ' ${dev ? t('devCryptoWarn') : t('encryptedLine')}',
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                style: _s(context, 12, color, w: dev ? FontWeight.w600 : null),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dayChip(BuildContext context, RipploColors c, int ts) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: SizedBox(
      height: 21,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 1.5,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(kRadiusPill),
                ),
                child: Center(
                  widthFactor: 1,
                  child: _u(
                    1,
                    Text(dayLabel(ts), style: _s(context, 12, c.text2)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _log(BuildContext context, RipploColors c) {
    return LayoutBuilder(
      builder: (context, bc) {
        final list = msgs;
        final items = <Widget>[_lockLine(context, c)];
        for (var i = 0; i < list.length; i++) {
          final m = list[i];
          if (i == 0 || !_sameDay(list[i - 1].ts, m.ts))
            items.add(_dayChip(context, c, m.ts));
          if (m.from == 'system') {
            items.add(
              Align(
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _FracText(
                    m.text ?? '',
                    _s(context, 12, c.warn),
                    16.8,
                    center: true,
                    dy: -.5,
                  ),
                ),
              ),
            );
          } else {
            items.add(_msg(context, c, m, bc.maxWidth * .78));
          }
        }
        if (typers.isNotEmpty) items.add(_typing(context, c));
        return OverflowBox(
          minWidth: bc.maxWidth + 32,
          maxWidth: bc.maxWidth + 32,
          minHeight: bc.maxHeight,
          maxHeight: bc.maxHeight,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: _onMetrics,
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: SingleChildScrollView(
                controller: scroll,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: gapped(items, 4, vertical: true),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _typing(BuildContext context, RipploColors c) => Align(
    alignment: Alignment.centerLeft,
    child: Semantics(
      liveRegion: true,
      label: t('typing'),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomRight: Radius.circular(18),
            bottomLeft: Radius.circular(6),
          ),
        ),
        child: Center(
          widthFactor: 1,
          child: RTypingDots(freeze: widget.typingFreeze),
        ),
      ),
    ),
  );

  Widget _msg(BuildContext context, RipploColors c, Msg m, double maxW) {
    final out = m.from == 'me';
    final fg = out ? c.onAccent : c.text;
    final swipeHere = offsetId == m.id && offsetX != 0;
    final restHere = offsetId == m.id && offsetRest;
    final status = m.status;
    final Widget? below;
    if (out && (status == 'out_of_range' || status == 'failed')) {
      below = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 15.4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: gapped([
              Lucide(LucideIcons.cloudOff, size: 14, color: c.danger),
              _u(
                0.5,
                Text(
                  status == 'failed' ? t('status_failed') : t('outOfMeshRange'),
                  style: _s(context, 11, c.danger),
                ),
              ),
              RBtn(
                text: t('retry'),
                sm: true,
                onTap: () => fire(api.retry(m.id)),
              ),
            ], 6),
          ),
        ),
      );
    } else if (out && (shown == m.id || status == 'delivered')) {
      below = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 15.4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: gapped([
              _u(0.5, Text(statusLabel(m), style: _s(context, 11, c.text2))),
              if (shown == m.id)
                RBtn(
                  text: t('unsend'),
                  sm: true,
                  kind: RBtnKind.ghost,
                  onTap: () => confirmUnsend(m),
                ),
            ], 6),
          ),
        ),
      );
    } else {
      below = null;
    }
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(out ? 18 : 6),
      bottomRight: Radius.circular(out ? 6 : 18),
    );
    Widget bubble = _SnapBox(
      color: out ? c.accent : c.surface2,
      radius: radius,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: DefaultTextStyle(
          style: _s(context, 15, fg),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: _bubbleKids(context, c, m, fg, out),
            ),
          ),
        ),
      ),
    );
    if (flashId == m.id) {
      bubble = TweenAnimationBuilder<double>(
        key: ValueKey(flashSeq),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1200),
        builder: (context, t, child) {
          final a = t < .6 ? 1.0 : 1 - Curves.ease.transform((t - .6) / .4);
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: c.accent.withValues(alpha: a),
                  spreadRadius: 3,
                ),
              ],
            ),
            child: child,
          );
        },
        child: bubble,
      );
    }
    final key = keys.putIfAbsent(m.id, GlobalKey.new);
    final moving = AnimatedContainer(
      duration: motion(
        context,
        restHere ? const Duration(milliseconds: 180) : Duration.zero,
      ),
      curve: Curves.ease,
      transform: Matrix4.translationValues(
        offsetId == m.id ? offsetX : 0,
        0,
        0,
      ),
      child: Listener(
        onPointerDown: (e) => onDown(e, m),
        onPointerMove: onMove,
        onPointerUp: (_) => endDrag(true),
        onPointerCancel: (_) => endDrag(false),
        child: GestureDetector(
          onTap: () => toggleStatus(m),
          onSecondaryTap: out ? () => confirmUnsend(m) : null,
          child: bubble,
        ),
      ),
    );
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              key: key,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: out
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [moving, ?below],
            ),
            if (swipeHere)
              Positioned(
                left: offsetX < 0 ? null : -30,
                right: offsetX < 0 ? -30 : null,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Opacity(
                    opacity: math.min(1, offsetX.abs() / _swipe),
                    child: Lucide(LucideIcons.reply, size: 20, color: c.text2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _bubbleKids(
    BuildContext context,
    RipploColors c,
    Msg m,
    Color fg,
    bool out,
  ) {
    final kids = <Widget>[];
    final re = m.re;
    if (re != null) {
      final rt = re['text'];
      kids.add(
        GestureDetector(
          onTap: () => jump(re['mid']),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                color: fg.withValues(alpha: .12),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(width: 3, color: fg),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _FracText(
                                whoName(re['who']),
                                _s(
                                  context,
                                  12,
                                  fg.withValues(alpha: .85),
                                  w: FontWeight.w700,
                                ),
                                16.8,
                                dy: -1,
                              ),
                              _FracText(
                                rt is String && rt.isNotEmpty
                                    ? rt
                                    : kindLabel(re['kind']),
                                _s(context, 12, fg.withValues(alpha: .75)),
                                16.8,
                                maxLines: 2,
                                dy: -1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final att = m.att;
    if (att != null && att.kind == 'image' && att.bytes != null) {
      kids.add(
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: GestureDetector(
              onTap: () => openImage(m),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 240,
                    maxHeight: 240,
                  ),
                  child: Image.memory(
                    att.bytes!,
                    cacheWidth: 720,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else if (att != null && att.kind == 'video' && att.bytes != null) {
      kids.add(
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _VideoBubble(
              key: ValueKey('v-${m.id}'),
              bytes: att.bytes!,
              mime: att.mime,
            ),
          ),
        ),
      );
    } else if (att != null && att.kind == 'voice') {
      final bars = voiceBars(m);
      final on = playing == m.id;
      kids.add(
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 190),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => fire(play(m)),
                child: Semantics(
                  button: true,
                  label: t('play'),
                  child: Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: fg,
                      shape: BoxShape.circle,
                    ),
                    child: Lucide(
                      on ? LucideIcons.pause : LucideIcons.play,
                      size: 18,
                      color: out ? c.accent : c.surface2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 26,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (var k = 0; k < bars.length; k++) ...[
                        if (k > 0) const SizedBox(width: 2),
                        Flexible(
                          child: SizedBox(
                            width: 3,
                            height: bars[k],
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: fg.withValues(alpha: .7),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _u(1, Text(dur(att.duration), style: _s(context, 12.5, fg))),
            ],
          ),
        ),
      );
    }
    final txt = m.text;
    kids.add(
      _Trail(
        span: txt != null && txt.isNotEmpty
            ? TextSpan(text: txt, style: _s(context, 15, fg))
            : null,
        meta: _meta(context, m, fg),
      ),
    );
    return kids;
  }

  Widget _meta(BuildContext context, Msg m, Color fg) {
    final kids = <Widget>[
      Text('${timeLabel(m.ts)} ', style: _s(context, 11, fg)),
    ];
    if (m.from == 'me') {
      switch (m.status) {
        case 'encrypting':
          kids.add(RSpin(child: Lucide(LucideIcons.lock, size: 12, color: fg)));
        case 'sending':
          final pr = m.progress;
          kids.add(
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: gapped([
                Lucide(LucideIcons.check, size: 14, color: fg),
                if (m.att != null && pr != null)
                  Text('${(pr * 100).round()}%', style: _s(context, 11, fg)),
              ], 2),
            ),
          );
        case 'delivered':
          kids.add(Lucide(LucideIcons.checkCheck, size: 14, color: fg));
        case 'failed':
          kids.add(Lucide(LucideIcons.circleAlert, size: 14, color: fg));
      }
    }
    return Opacity(
      opacity: .75,
      child: SizedBox(
        height: 15.4,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: gapped(kids, 3),
        ),
      ),
    );
  }

  Widget _viewer(BuildContext context, EdgeInsets pad) {
    final bytes = viewer!.att!.bytes!;
    return Positioned.fill(
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => viewer = null),
              child: Container(
                color: const Color(0xEB000000),
                padding: EdgeInsets.fromLTRB(
                  12,
                  pad.top + 56,
                  12,
                  pad.bottom + 12,
                ),
                alignment: Alignment.center,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
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
                onTap: () => setState(() => viewer = null),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _replyBar(BuildContext context, RipploColors c) {
    final r = replyTo!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.border, width: kBorderWidth),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Lucide(LucideIcons.reply, size: 18, color: c.text2),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _u(
                    1,
                    Text(
                      authorOf(r),
                      style: _s(context, 12, c.text, w: FontWeight.w700),
                    ),
                  ),
                  _u(
                    1,
                    Text(
                      snippet(r),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: _s(context, 12, c.text2),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            RIconBtn(
              icon: LucideIcons.x,
              size: 20,
              stroke: 2,
              color: c.text2,
              label: t('cancel'),
              onTap: () => setState(() => replyTo = null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stagedRow(BuildContext context, RipploColors c) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: SizedBox(
      height: 64,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: gapped([
            for (var i = 0; i < staged.length; i++)
              SizedBox(
                key: ObjectKey(staged[i]),
                width: 64,
                height: 64,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: c.surface2),
                      _thumb(staged[i]),
                      Positioned(
                        top: 3,
                        right: 3,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => staged.removeAt(i)),
                          child: Semantics(
                            button: true,
                            label: t('cancel'),
                            child: Container(
                              width: 20,
                              height: 20,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                color: Color(0x99000000),
                                shape: BoxShape.circle,
                              ),
                              child: const Lucide(
                                LucideIcons.x,
                                size: 14,
                                color: Color(0xFFFFFFFF),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ], 8),
        ),
      ),
    ),
  );

  Widget _thumb(StagedMedia s) {
    if (s.kind == 'video')
      return s.path == null
          ? const SizedBox.shrink()
          : _VideoThumb(path: s.path!);
    final b = s.bytes;
    return b != null
        ? Image.memory(
            b,
            fit: BoxFit.cover,
            cacheWidth: 192,
            gaplessPlayback: true,
          )
        : Image.file(
            File(s.path!),
            fit: BoxFit.cover,
            cacheWidth: 192,
            gaplessPlayback: true,
          );
  }

  Widget _composer(BuildContext context, RipploColors c) {
    final mq = MediaQuery.of(context);
    final bottom = math.max(mq.padding.bottom, mq.viewInsets.bottom) + 8;
    final has = text.text.trim().isNotEmpty || staged.isNotEmpty;
    final len = text.text.length;
    final Widget row;
    if (rec) {
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: gapped([
          RIconBtn(
            icon: LucideIcons.x,
            size: 22,
            stroke: 2,
            label: t('cancel'),
            onTap: () => fire(stopRec(true)),
          ),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              alignment: Alignment.center,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: gapped([
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: c.danger,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Text(dur(recSec), style: _s(context, 15, c.text)),
                  Expanded(
                    child: SizedBox(
                      height: 28,
                      child: ClipRect(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: gapped([
                            for (final h in liveBars)
                              Container(
                                width: 3,
                                height: h.toDouble(),
                                decoration: BoxDecoration(
                                  color: c.accent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                          ], 2),
                        ),
                      ),
                    ),
                  ),
                ], 8),
              ),
            ),
          ),
          _sendBtn(c, () => fire(stopRec(false))),
        ], 6),
      );
    } else {
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: gapped([
          RIconBtn(
            icon: LucideIcons.plus,
            size: 22,
            stroke: 2,
            label: t('attach'),
            onTap: () => fire(pickFiles()),
          ),
          Expanded(child: _box(context, c, len)),
          if (has)
            _sendBtn(c, () => fire(send()))
          else
            RIconBtn(
              icon: LucideIcons.mic,
              size: 22,
              stroke: 2,
              label: t('recordVoice'),
              onTap: () => fire(startRec()),
            ),
        ], 6),
      );
    }
    return Padding(padding: EdgeInsets.fromLTRB(0, 8, 0, bottom), child: row);
  }

  Widget _sendBtn(RipploColors c, VoidCallback onTap) => Pressable(
    onTap: onTap,
    label: t('send'),
    radius: 22,
    builder: (context, pressed) => Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
      child: Lucide(LucideIcons.send, size: 20, color: c.onAccent),
    ),
  );

  Widget _box(BuildContext context, RipploColors c, int len) {
    final style = _s(context, 15, c.text, h: 1.35).copyWith(letterSpacing: 0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: c.border, width: kBorderWidth),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: gapped([
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36.25),
              child: Material(
                type: MaterialType.transparency,
                child: TextField(
                  controller: text,
                  focusNode: focus,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.send,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: onText,
                  onSubmitted: (_) {
                    fire(send());
                    focus.requestFocus();
                  },
                  style: style,
                  cursorColor: c.text,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    hintText: t('message'),
                    hintStyle: style.copyWith(color: const Color(0xFF757575)),
                  ),
                ),
              ),
            ),
          ),
          if (len >= 900)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '$len/${api.maxText}',
                style: _s(context, 11, len >= api.maxText ? c.danger : c.text2),
              ),
            ),
        ], 6),
      ),
    );
  }
}

extension _Fallback on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _FracText extends LeafRenderObjectWidget {
  const _FracText(
    this.text,
    this.style,
    this.lineHeight, {
    this.maxLines,
    this.center = false,
    this.dy = 0,
  });

  final String text;
  final TextStyle style;
  final double lineHeight;
  final int? maxLines;
  final bool center;
  final double dy;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFracText(this, MediaQuery.textScalerOf(context));

  @override
  void updateRenderObject(BuildContext context, _RenderFracText r) =>
      r.update(this, MediaQuery.textScalerOf(context));
}

class _RenderFracText extends RenderBox {
  _RenderFracText(_FracText w, TextScaler scaler) {
    update(w, scaler);
  }

  late _FracText _w;
  late TextPainter _tp;

  void update(_FracText w, TextScaler scaler) {
    _w = w;
    _tp = TextPainter(
      text: TextSpan(text: w.text, style: w.style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: w.maxLines,
      ellipsis: w.maxLines == null ? null : '…',
      textAlign: w.center ? TextAlign.center : TextAlign.start,
    );
    markNeedsLayout();
    markNeedsPaint();
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    _tp.layout();
    return _tp.width;
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) {
    _tp.layout(maxWidth: width);
    return _tp.computeLineMetrics().length * _w.lineHeight;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    _tp.layout(maxWidth: constraints.maxWidth);
    final w = _w.center || constraints.hasTightWidth
        ? constraints.maxWidth
        : _tp.width;
    return constraints.constrain(
      Size(w, _tp.computeLineMetrics().length * _w.lineHeight),
    );
  }

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
    _tp.layout(minWidth: size.width, maxWidth: size.width);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final lines = _tp.computeLineMetrics().length;
    final shift = (_w.lineHeight - _tp.height / lines) / 2 + _w.dy;
    _tp.paint(context.canvas, offset + Offset(0, shift));
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..label = _w.text
      ..textDirection = TextDirection.ltr;
  }

  @override
  void dispose() {
    _tp.dispose();
    super.dispose();
  }
}

class _SnapBox extends SingleChildRenderObjectWidget {
  const _SnapBox({
    required this.color,
    required this.radius,
    required super.child,
  });

  final Color color;
  final BorderRadius radius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSnapBox(color, radius, MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(BuildContext context, _RenderSnapBox r) => r
    ..color = color
    ..radius = radius
    ..dpr = MediaQuery.devicePixelRatioOf(context);
}

class _RenderSnapBox extends RenderProxyBox {
  _RenderSnapBox(this._color, this._radius, this._dpr);

  Color _color;
  BorderRadius _radius;
  double _dpr;

  set color(Color v) {
    if (v == _color) return;
    _color = v;
    markNeedsPaint();
  }

  set radius(BorderRadius v) {
    if (v == _radius) return;
    _radius = v;
    markNeedsPaint();
  }

  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsPaint();
  }

  double _snap(double v) => (v * _dpr).round() / _dpr;

  @override
  void paint(PaintingContext context, Offset offset) {
    final g = localToGlobal(Offset.zero);
    final l = _snap(g.dx);
    final t = _snap(g.dy);
    final r = _snap(g.dx + size.width);
    final b = _snap(g.dy + size.height);
    final rect = Rect.fromLTRB(
      l - g.dx,
      t - g.dy,
      r - g.dx,
      b - g.dy,
    ).shift(offset);
    context.canvas.drawRRect(_radius.toRRect(rect), Paint()..color = _color);
    super.paint(context, offset);
  }
}

class _Trail extends SingleChildRenderObjectWidget {
  const _Trail({this.span, required Widget meta}) : super(child: meta);

  final TextSpan? span;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTrail(span, MediaQuery.textScalerOf(context));

  @override
  void updateRenderObject(BuildContext context, _RenderTrail r) => r
    ..span = span
    ..scaler = MediaQuery.textScalerOf(context);
}

class _RenderTrail extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderTrail(this._span, this._scaler) {
    _rebuild();
  }

  static const double _gap = 10;
  static const double _top = 6;
  static const double _bottom = -4;

  TextSpan? _span;
  TextScaler _scaler;
  late TextPainter _tp;

  void _rebuild() {
    _tp = TextPainter(
      text: _span,
      textDirection: TextDirection.ltr,
      textScaler: _scaler,
    );
  }

  set span(TextSpan? v) {
    if (v == _span ||
        (v != null &&
            _span != null &&
            v.toPlainText() == _span!.toPlainText() &&
            v.style == _span!.style)) {
      return;
    }
    _span = v;
    _rebuild();
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  set scaler(TextScaler v) {
    if (v == _scaler) return;
    _scaler = v;
    _rebuild();
    markNeedsLayout();
  }

  RenderBox get _m => child!;
  bool get _hasText => _span != null;

  @override
  double computeMaxIntrinsicWidth(double height) {
    var t = 0.0;
    if (_hasText) {
      _tp.layout();
      t = _tp.width;
    }
    return t + _m.getMaxIntrinsicWidth(double.infinity) + _gap;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _m.getMinIntrinsicWidth(double.infinity) + _gap;

  @override
  double computeMinIntrinsicHeight(double width) {
    var t = 0.0;
    if (_hasText) {
      _tp.layout(maxWidth: width);
      t = _tp.height;
    }
    return t + _top + _m.getMinIntrinsicHeight(double.infinity) + _bottom;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final w = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : computeMaxIntrinsicWidth(double.infinity);
    return constraints.constrain(Size(w, computeMinIntrinsicHeight(w)));
  }

  Offset _mOffset = Offset.zero;

  @override
  void performLayout() {
    final maxW = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : computeMaxIntrinsicWidth(double.infinity);
    _m.layout(BoxConstraints(maxWidth: maxW), parentUsesSize: true);
    final mw = _m.size.width + _gap;
    var th = 0.0;
    var fits = false;
    var lineTop = 0.0;
    var textW = 0.0;
    if (_hasText) {
      _tp.layout(maxWidth: maxW);
      th = _tp.height;
      textW = _tp.width;
      final lines = _tp.computeLineMetrics();
      if (lines.isNotEmpty) {
        final last = lines.last;
        fits = last.left + last.width + mw <= maxW + .01;
        lineTop = th - last.height;
      }
    }
    final width = constraints.hasTightWidth
        ? maxW
        : constraints.constrainWidth(math.max(textW + (fits ? mw : 0), mw));
    final base = fits ? lineTop : th;
    _mOffset = Offset(width - _m.size.width, base + _top);
    size = constraints.constrain(
      Size(width, math.max(th, base + _top + _m.size.height + _bottom)),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_hasText) _tp.paint(context.canvas, offset - const Offset(0, 1));
    context.paintChild(_m, offset + _mOffset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: _mOffset,
        position: position,
        hitTest: (r, p) => _m.hitTest(r, position: p),
      );

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_hasText) {
      config
        ..label = _span!.toPlainText()
        ..textDirection = TextDirection.ltr;
    }
  }

  @override
  void dispose() {
    _tp.dispose();
    super.dispose();
  }
}

class _VideoBubble extends StatefulWidget {
  const _VideoBubble({super.key, required this.bytes, required this.mime});

  final Uint8List bytes;
  final String mime;

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  VideoPlayerController? ctl;
  String? path;
  bool busy = false;

  Future<void> start() async {
    if (busy) return;
    final live = ctl;
    if (live != null) {
      live.value.isPlaying ? await live.pause() : await live.play();
      return;
    }
    setState(() => busy = true);
    try {
      final p = await writeMedia(widget.bytes, widget.mime);
      path = p;
      final c = VideoPlayerController.file(File(p));
      await c.initialize();
      c.addListener(() {
        final v = c.value;
        if (v.isInitialized &&
            !v.isPlaying &&
            v.duration > Duration.zero &&
            v.position >= v.duration) {
          fire(release());
        }
      });
      if (!mounted) {
        await c.dispose();
        await deleteMedia(p);
        return;
      }
      setState(() => ctl = c);
      await c.play();
    } catch (_) {
      await release();
      toast(t('playFailed'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void fire(Future<void> f) => js.fire(f);

  Future<void> release() async {
    final c = ctl;
    final p = path;
    ctl = null;
    path = null;
    if (mounted) setState(() {});
    try {
      await c?.dispose();
    } catch (_) {}
    await deleteMedia(p);
  }

  @override
  void dispose() {
    final c = ctl;
    final p = path;
    ctl = null;
    path = null;
    fire(() async {
      try {
        await c?.dispose();
      } catch (_) {}
      await deleteMedia(p);
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ctl;
    final Widget inner;
    if (c != null && c.value.isInitialized) {
      inner = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio == 0 ? 1 : c.value.aspectRatio,
          child: VideoPlayer(c),
        ),
      );
    } else {
      inner = Container(
        width: 240,
        height: 135,
        alignment: Alignment.center,
        color: const Color(0xFF000000),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0x99000000),
            shape: BoxShape.circle,
          ),
          child: const Lucide(
            LucideIcons.play,
            size: 22,
            color: Color(0xFFFFFFFF),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () => fire(start()),
      child: ClipRRect(borderRadius: BorderRadius.circular(14), child: inner),
    );
  }
}

class _VideoThumb extends StatefulWidget {
  const _VideoThumb({required this.path});

  final String path;

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  late final VideoPlayerController ctl = VideoPlayerController.file(
    File(widget.path),
  );
  bool ready = false;

  @override
  void initState() {
    super.initState();
    ctl.initialize().then((_) {
      if (mounted) setState(() => ready = true);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ready
      ? FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: ctl.value.size.width,
            height: ctl.value.size.height,
            child: VideoPlayer(ctl),
          ),
        )
      : const SizedBox.shrink();
}
