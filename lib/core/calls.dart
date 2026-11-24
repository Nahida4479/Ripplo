import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/call_frame.dart';
import '../crypto/identity.dart';
import '../util/bytes.dart';
import '../util/js.dart' as js;
import 'call_audio.dart';
import 'state.dart';

const _defaultTiming = <String, int>{
  'ring': 45000,
  'silence': 6000,
  'first': 30000,
  'hold': 2500,
  'stale': 120000,
  'warn': 4,
  'gone': 8000,
};
const _quiet = 0.003;
const _idLen = 8;
const _keyLen = 32;

Uint8List? _decode(Object? s, int len) {
  try {
    final b = unb64('$s');
    return b.length == len ? b : null;
  } catch (_) {
    return null;
  }
}

class _Call {
  _Call(this.peer, this.role, this.id) : idB64 = b64(id);

  final String peer;
  final int role;
  final Uint8List id;
  final String idB64;
  SecretKey? key;
  CallAudio? audio;
  int seq = 0;
  bool live = false;
  bool done = false;
  bool heard = false;
  final Replay replay = createReplay();
  int lastRx = 0;
  int liveAt = 0;
  Timer? ringTimer;
  Timer? watch;
  int micQuiet = 0;
  int outQuiet = 0;
  int lastRecv = 0;
  bool fellBack = false;
  String? node;
  int goneAt = 0;
}

class Calls {
  Calls({
    required this.state,
    required this.signal,
    required this.sendMedia,
    required this.hasNeighbor,
    required this.supported,
    required this.newAudio,
    required this.notify,
    required this.log,
    this.ensureMic = _noMic,
    Map<String, int> timing = const {},
  }) : _t = {..._defaultTiming, ...timing};

  final RipploState state;
  final Future<bool> Function(String peer, Map<String, Object?> body) signal;
  final bool Function(String peer, Uint8List packet, String? node) sendMedia;
  final bool Function(String peer, String? node) hasNeighbor;
  final bool Function() supported;
  final Future<CallAudio> Function() newAudio;
  final Future<void> Function() ensureMic;
  final void Function(String peer) notify;
  final void Function(String peer, String reason, int ms) log;
  final Map<String, int> _t;
  _Call? _cur;

  static Future<void> _noMic() async {}

  void _set(Map<String, Object?> patch) =>
      state.call = {...?state.call, ...patch};

  bool get _ringing => state.call?.status == 'ringing';

  void _finish(_Call c, String reason, String? tell) {
    if (c.done) return;
    c.done = true;
    c.ringTimer?.cancel();
    c.watch?.cancel();
    if (tell != null) {
      js.fire(signal(c.peer, {'t': 'call', 'k': tell, 'id': c.idB64}));
    }
    c.audio?.stop();
    final startedAt = state.call?.startedAt ?? 0;
    log(c.peer, reason, startedAt != 0 ? js.now() - startedAt : 0);
    _set({'status': 'ended', 'reason': reason});
    if (identical(_cur, c)) _cur = null;
    Timer(Duration(milliseconds: _t['hold']!), () {
      final cur = state.call;
      if (cur != null && cur.status == 'ended' && cur.peer == c.peer) {
        state.call = null;
      }
    });
  }

  Future<void> _begin(_Call c) async {
    c.ringTimer?.cancel();
    _set({'status': 'connecting'});
    try {
      await ensureMic();
      c.audio = await newAudio();
      if (c.done) {
        c.audio!.stop();
        return;
      }
      await c.audio!.start((frames) => js.fire(_sendFrames(c, frames)));
    } catch (_) {
      try {
        c.audio?.stop();
      } catch (_) {}
      _finish(c, 'mic', 'end');
      return;
    }
    if (c.done) {
      c.audio!.stop();
      return;
    }
    c.live = true;
    c.lastRx = js.now();
    c.liveAt = js.now();
    _set({'status': 'active', 'startedAt': js.now()});
    c.watch = Timer.periodic(const Duration(seconds: 1), (_) => _tick(c));
  }

  Future<void> _sendFrames(_Call c, List<Uint8List> frames) async {
    if (!identical(_cur, c) || c.done || !c.live) return;
    final packet = await sealFrame(
      c.key!,
      c.id,
      c.role,
      c.seq++,
      packFrames(frames),
    );
    sendMedia(c.peer, packet, c.node);
  }

  void _tick(_Call c) {
    final audio = c.audio!;
    final st = audio.stats();
    final mic = (st['mic'] as num?) ?? 0;
    final out = (st['out'] as num?) ?? 0;
    final recv = (st['recv'] as num?)?.toInt() ?? 0;
    final warnAfter = _t['warn']!;
    c.micQuiet = state.call?.muted != true && mic < _quiet ? c.micQuiet + 1 : 0;
    if (c.micQuiet >= warnAfter && !c.fellBack) {
      c.fellBack = true;
      c.micQuiet = 0;
      js.fire(audio.fallback());
    }
    c.outQuiet = recv > c.lastRecv && out < _quiet ? c.outQuiet + 1 : 0;
    c.lastRecv = recv;
    final warn = c.micQuiet >= warnAfter
        ? 'mic'
        : c.outQuiet >= warnAfter
        ? 'out'
        : !c.heard && js.now() - c.liveAt > warnAfter * 1000
        ? 'none'
        : '';
    _set({'stats': st, 'warn': warn});
    if (hasNeighbor(c.peer, c.node)) {
      c.goneAt = 0;
    } else if (c.goneAt == 0) {
      c.goneAt = js.now();
    }
    final limit = c.heard ? _t['silence']! : _t['first']!;
    if (js.now() - c.lastRx > limit ||
        (c.goneAt != 0 && js.now() - c.goneAt > _t['gone']!)) {
      _finish(c, 'lost', 'end');
    }
  }

  Future<void> start(String peer) async {
    if (_cur != null) throw RipploError('call_busy');
    if (!supported()) throw RipploError('call_unsupported');
    try {
      await ensureMic();
    } catch (_) {
      throw RipploError('call_mic');
    }
    if (!hasNeighbor(peer, null)) throw RipploError('call_no_link');
    final raw = random(_keyLen);
    final c = _Call(peer, 0, random(_idLen));
    _cur = c;
    state.call = {
      'peer': peer,
      'dir': 'out',
      'status': 'ringing',
      'muted': false,
      'startedAt': 0,
      'id': c.idB64,
    };
    c.key = importCallKey(raw);
    if (c.done) return;
    c.ringTimer = Timer(
      Duration(milliseconds: _t['ring']!),
      () => _finish(c, 'noanswer', 'end'),
    );
    js.fire(
      signal(peer, {
        't': 'call',
        'k': 'offer',
        'id': c.idB64,
        'key': b64(raw),
        'ts': js.now(),
      }).then<void>((ok) {
        if (!ok && !c.done && _ringing) _finish(c, 'unreachable', null);
      }),
    );
  }

  Future<void> _onOffer(String f, Map<String, Object?> msg) async {
    final id = _decode(msg['id'], _idLen);
    final raw = _decode(msg['key'], _keyLen);
    if (id == null || raw == null) return;
    final ts = msg['ts'];
    if (js.isFiniteNum(ts) && js.now() - (ts as num) > _t['stale']!) return;
    final cur = _cur;
    if (cur != null && msg['id'] == cur.idB64) return;
    if (cur != null || !supported()) {
      js.fire(
        signal(f, {'t': 'call', 'k': 'decline', 'id': msg['id'], 'r': 'busy'}),
      );
      return;
    }
    final c = _Call(f, 1, id);
    _cur = c;
    state.call = {
      'peer': f,
      'dir': 'in',
      'status': 'ringing',
      'muted': false,
      'startedAt': 0,
      'id': c.idB64,
    };
    c.key = importCallKey(raw);
    notify(f);
    c.ringTimer = Timer(
      Duration(milliseconds: _t['ring']!),
      () => _finish(c, 'missed', null),
    );
  }

  Future<void> onSignal(String f, Map<String, Object?> msg) async {
    final k = msg['k'];
    if (k == 'offer') return _onOffer(f, msg);
    final c = _cur;
    if (c == null || c.peer != f || msg['id'] != c.idB64) return;
    if (k == 'accept' && c.role == 0 && _ringing) {
      await _begin(c);
    } else if (k == 'decline') {
      _finish(c, msg['r'] == 'busy' ? 'busy' : 'declined', null);
    } else if (k == 'end') {
      _finish(c, c.role == 1 && _ringing ? 'missed' : 'ended', null);
    }
  }

  Future<void> accept() async {
    final c = _cur;
    if (c == null || c.role != 1 || !_ringing) return;
    c.ringTimer?.cancel();
    js.fire(signal(c.peer, {'t': 'call', 'k': 'accept', 'id': c.idB64}));
    await _begin(c);
  }

  void hangup() {
    final c = _cur;
    if (c == null) return;
    final ringing = _ringing;
    if (c.role == 1 && ringing) {
      _finish(c, 'declined', 'decline');
    } else {
      _finish(c, ringing ? 'cancelled' : 'ended', 'end');
    }
  }

  Future<void> onMedia(Uint8List bytes, String? node) async {
    final c = _cur;
    if (c == null || !c.live) return;
    ({int seq, Uint8List plain}) opened;
    try {
      opened = await openFrame(c.key!, c.id, 1 - c.role, bytes);
    } catch (_) {
      return;
    }
    if (!identical(_cur, c) || !c.replay.accept(opened.seq)) return;
    List<Uint8List> frames;
    try {
      frames = unpackFrames(opened.plain);
    } catch (_) {
      return;
    }
    c.lastRx = js.now();
    c.heard = true;
    if (node != null && node.isNotEmpty) c.node = node;
    c.audio!.play(frames);
  }

  void setMuted(bool muted) {
    final c = _cur;
    if (c == null) return;
    c.audio?.setMuted(muted);
    _set({'muted': muted});
  }
}
