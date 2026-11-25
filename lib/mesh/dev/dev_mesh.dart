import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../data/db.dart';
import '../../util/bytes.dart';
import '../bridge.dart';
import 'dev_signal.dart';
import '../packet.dart';
import '../router.dart';

const _basePort = 47700;
const _portCount = 32;
const _nodeLen = 32;
const _kbps = 20000;
const _helloMs = 2000;
const _dropMs = 5000;
const _granted = {
  'bluetooth': 'granted',
  'wifi': 'granted',
  'notifications': 'granted',
  'microphone': 'granted',
};

enum DevFrameType { hello, bye, pkt }

class DevFrame {
  DevFrame(this.type, this.from, [this.to = '', Uint8List? bytes])
    : bytes = bytes ?? _empty;

  static final _empty = Uint8List(0);

  final DevFrameType type;
  final String from;
  final String to;
  final Uint8List bytes;

  Uint8List encode() {
    final out = BytesBuilder(copy: false)
      ..addByte(type.index + 1)
      ..add(ascii.encode(from.padRight(_nodeLen)))
      ..add(ascii.encode(to.padRight(_nodeLen)))
      ..add(bytes);
    return out.takeBytes();
  }

  static DevFrame? decode(Uint8List d) {
    if (d.length < 1 + 2 * _nodeLen || d[0] < 1 || d[0] > 3) return null;
    try {
      return DevFrame(
        DevFrameType.values[d[0] - 1],
        ascii.decode(d.sublist(1, 1 + _nodeLen)).trim(),
        ascii.decode(d.sublist(1 + _nodeLen, 1 + 2 * _nodeLen)).trim(),
        d.sublist(1 + 2 * _nodeLen),
      );
    } on FormatException {
      return null;
    }
  }
}

class DevHub {
  final Map<Object, void Function(DevFrame)> _subs = {};

  int get size => _subs.length;

  void _join(Object who, void Function(DevFrame) onFrame) =>
      _subs[who] = onFrame;

  void _leave(Object who) => _subs.remove(who);

  void _broadcast(Object from, DevFrame f) {
    for (final e in _subs.entries.toList()) {
      if (identical(e.key, from)) continue;
      scheduleMicrotask(() => e.value(f));
    }
  }
}

int _slot(String profile) {
  if (profile.isEmpty) return 0;
  var h = 0x811c9dc5;
  for (final c in profile.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h % _portCount;
}

DevMeshError _unsupported() => const DevMeshError();

class DevMeshError extends MeshError {
  const DevMeshError() : super('unsupported', 'unsupported');
}

class DevMesh implements Mesh {
  DevMesh({String? profile, bool? solo, Directory? dir})
    : this._(
        profile ?? const String.fromEnvironment('RIPPLO_PROFILE'),
        solo ?? const bool.fromEnvironment('RIPPLO_SOLO'),
        dir,
      );

  DevMesh._(this._profile, this._solo, Directory? dir)
    : _dir =
          dir ??
          Directory(
            '${Directory.systemTemp.path}/ripplo-dev-${_profile.isEmpty ? 'default' : _profile}',
          ),
      _hub = null,
      _now = (() => DateTime.now().millisecondsSinceEpoch) {
    _guard();
  }

  DevMesh.memory(DevHub hub, {bool solo = false, int Function()? now})
    : _profile = '',
      _solo = solo,
      _dir = null,
      _hub = hub,
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _guard();
  }

  final String _profile;
  final bool _solo;
  final Directory? _dir;
  final DevHub? _hub;
  final int Function() _now;

  final String nodeTag = hex(random(16));
  final Map<String, List<void Function(Map<String, Object?>)>> _listeners = {};
  final Map<String, int> _peers = {};
  Router? _router;
  Timer? _timer;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  void Function(DevFrame)? _tx;
  Future<RawStore>? _rawFuture;

  late final DevSignal _signal = DevSignal(store: _bundleStore());

  static void _guard() {
    if (kReleaseMode) {
      throw StateError('DevMesh is not available in release builds');
    }
  }

  DevBundleStore? _bundleStore() {
    final d = _dir;
    if (d == null) return null;
    final f = File('${d.path}/bundle.bin');
    return DevBundleStore(
      get: () => f.existsSync() ? f.readAsBytesSync() : null,
      set: (b) {
        d.createSync(recursive: true);
        f.writeAsBytesSync(b, flush: true);
      },
    );
  }

  Future<RawStore> get _raw => _rawFuture ??= () async {
    final d = _dir;
    if (d == null) return MemoryRawStore();
    await d.create(recursive: true);
    return FileRawStore.open(File('${d.path}/db.json'));
  }();

  void _emit(String ev, Map<String, Object?> d) {
    for (final cb in List.of(_listeners[ev] ?? const [])) {
      cb(d);
    }
  }

  void _hello() => _tx?.call(DevFrame(DevFrameType.hello, nodeTag));

  void _drop(String node) {
    _peers.remove(node);
    _router?.linkDown(node);
    _emit('neighbor', {
      'node': node,
      'up': false,
      'medium': 'lan',
      'kbps': _kbps,
    });
  }

  void _see(String node) {
    if (!_peers.containsKey(node)) {
      _router!.linkUp(node);
      _emit('neighbor', {
        'node': node,
        'up': true,
        'medium': 'lan',
        'kbps': _kbps,
      });
      _hello();
    }
    _peers[node] = _now();
  }

  void _onFrame(DevFrame m) {
    final r = _router;
    if (_solo || r == null || m.from == nodeTag) return;
    switch (m.type) {
      case DevFrameType.hello:
        _see(m.from);
      case DevFrameType.bye:
        if (_peers.containsKey(m.from)) _drop(m.from);
      case DevFrameType.pkt:
        if (m.to == nodeTag) {
          _see(m.from);
          r.onPacket(m.bytes, m.from);
        }
    }
  }

  @visibleForTesting
  void sweep() {
    for (final e in _peers.entries.toList()) {
      if (_now() - e.value > _dropMs) _drop(e.key);
    }
  }

  Future<void> _openWire() async {
    if (_solo) return;
    final hub = _hub;
    if (hub != null) {
      hub._join(this, _onFrame);
      _tx = (f) => hub._broadcast(this, f);
      return;
    }
    final start = _slot(_profile);
    for (var i = 0; i < _portCount; i++) {
      try {
        _socket = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          _basePort + (start + i) % _portCount,
          reuseAddress: false,
        );
        break;
      } on SocketException {
        continue;
      }
    }
    final s = _socket;
    if (s == null) throw const MeshError('no_port', 'no free dev mesh port');
    _sub = s.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = s.receive();
      final f = d == null ? null : DevFrame.decode(d.data);
      if (f != null) _onFrame(f);
    });
    _tx = (f) {
      final data = f.encode();
      for (var p = 0; p < _portCount; p++) {
        s.send(data, InternetAddress.loopbackIPv4, _basePort + p);
      }
    };
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    _tx?.call(DevFrame(DevFrameType.bye, nodeTag));
    _hub?._leave(this);
    await _sub?.cancel();
    _socket?.close();
    _socket = null;
    _tx = null;
    _router = null;
    _peers.clear();
    final raw = await _rawFuture;
    await raw?.close();
  }

  Router get _r {
    final r = _router;
    if (r == null) throw const MeshError('not_started', 'mesh not started');
    return r;
  }

  @override
  bool get isNative => false;

  @override
  bool get devCrypto => true;

  @override
  Future<({Uint8List bundle, Uint8List ik})> signalInit() =>
      _signal.signalInit();

  @override
  Future<String> signalAddContact(Uint8List bundle) =>
      _signal.signalAddContact(bundle);

  @override
  Future<Uint8List> signalSeal(String tag, Uint8List plaintext) =>
      _signal.signalSeal(tag, plaintext);

  @override
  Future<({String tag, Uint8List ik, Uint8List plaintext})> signalOpen(
    Uint8List payload,
  ) => _signal.signalOpen(payload);

  @override
  Future<Uint8List> signalProof(
    Uint8List ik,
    Uint8List n,
    Uint8List challengerTag,
    Uint8List proverTag,
  ) => _signal.signalProof(ik, n, challengerTag, proverTag);

  @override
  Future<String> signalSafetyNumber(Uint8List ik) =>
      _signal.signalSafetyNumber(ik);

  @override
  Future<void> signalForget(String tag) => _signal.signalForget(tag);

  @override
  Future<String> start(Uint8List selfTag) async {
    if (_router != null) return nodeTag;
    await _openWire();
    _router = Router(
      selfTag: selfTag,
      sendTo: (to, bytes) =>
          _tx?.call(DevFrame(DevFrameType.pkt, nodeTag, to, bytes)),
      deliver: (packet, from) =>
          _emit('packet', {'packet': packet, 'from': from}),
    );
    _hello();
    _timer = Timer.periodic(const Duration(milliseconds: _helloMs), (_) {
      _hello();
      sweep();
    });
    return nodeTag;
  }

  @override
  Future<int> send(Uint8List packet) async {
    final r = _r;
    r.onPacket(packet, selfNode);
    return r.neighbors().length;
  }

  @override
  Future<void> sendApp(String node, Uint8List payload) async {
    _r;
    _tx?.call(
      DevFrame(
        DevFrameType.pkt,
        nodeTag,
        node,
        encodePacket(type: PacketType.app, payload: payload),
      ),
    );
  }

  @override
  Future<List<Map<String, Object?>>> getNeighbors() async => [
    for (final node in _r.neighbors())
      {
        'node': node,
        'medium': 'lan',
        'kbps': _kbps,
        'rttMs': 1,
        'links': [
          {'medium': 'lan', 'kbps': _kbps},
        ],
      },
  ];

  @override
  Future<String> getDiag() async => '';

  @override
  Future<void> clearDiag() async {}

  @override
  Future<bool> usbLog(String text) async => false;

  @override
  Future<List<Map<String, Object?>>> getTransports() async => [
    {'name': 'broadcast', 'running': true, 'unsupported': false},
  ];

  @override
  Future<bool> devConnect(String node, String spec) async => false;

  @override
  Future<void> devDisconnect(String node, String medium) async {}

  @override
  Future<String> getDeviceInfo() async => '';

  @override
  Future<({bool coded, bool extended})> getBleCaps() async =>
      (coded: false, extended: false);

  @override
  Future<List<InboxItem>> drainInbox() async => [];

  @override
  Future<bool> isLocked() async => false;

  @override
  Future<void> keepAwake(bool on) async {}

  @override
  Future<void> endLockedCall() async {}

  @override
  Future<Map<String, Object?>?> takeOpen() async => null;

  @override
  Future<({Uint8List key, bool insecure})> getDbKey() async {
    final raw = await _raw;
    var k = await raw.get('prefs', 'dbkey');
    if (k == null) {
      k = random(32);
      await raw.put('prefs', 'dbkey', k);
    }
    return (key: k, insecure: true);
  }

  @override
  Future<String?> selfHash() async => null;

  @override
  Future<bool> fromPlay() async => false;

  @override
  Future<void> installUpdate(String url, String sha256, bool prompt) async =>
      throw _unsupported();

  @override
  Future<void> requestBatteryExemption() async {}

  @override
  Future<void> setAutoUpdate(bool enabled) async {}

  @override
  Future<void> requestFullScreen() async {}

  @override
  Future<void> startRing() async => throw _unsupported();

  @override
  Future<void> stopRing() async {}

  @override
  Future<Map<String, Object?>?> takeShare() async => null;

  @override
  Future<Map<String, String>> checkPermissions() async => Map.of(_granted);

  @override
  Future<Map<String, String>> requestPermissions() async => Map.of(_granted);

  @override
  Future<void> dbPut(
    String store,
    String key,
    String? idx,
    Uint8List value,
  ) async => (await _raw).put(store, key, value, idx: idx);

  @override
  Future<Uint8List?> dbGet(String store, String key) async =>
      (await _raw).get(store, key);

  @override
  Future<void> dbDel(String store, String key) async =>
      (await _raw).del(store, key);

  @override
  Future<List<String>> dbKeys(String store, {String? prefix}) async =>
      (await _raw).keys(store, prefix: prefix);

  @override
  Future<List<(String, Uint8List)>> dbAll(String store) async =>
      (await _raw).all(store);

  @override
  Future<List<(String, Uint8List)>> dbByIdx(String store, String idx) async =>
      (await _raw).byIdx(idx);

  @override
  Future<({bool biometric, bool deviceCredential})> authAvailable() async =>
      (biometric: false, deviceCredential: false);

  @override
  Future<bool> authenticate(String reason) async => true;

  @override
  Future<void> setSecure(bool on) async {}

  @override
  Future<Map<String, Object?>> backupStatus() async => {
    'enabled': false,
    'lastAt': 0,
    'folder': null,
  };

  @override
  Future<String> backupEnable() async => throw _unsupported();

  @override
  Future<String> backupShowCode() async => throw _unsupported();

  @override
  Future<void> backupDisable() async => throw _unsupported();

  @override
  Future<String> backupChooseFolder() async => throw _unsupported();

  @override
  Future<Map<String, Object?>> backupCreate(
    String mode,
    Map<String, Object?> meta,
  ) async => throw _unsupported();

  @override
  Future<Map<String, Object?>> backupRestore(String code) async =>
      throw _unsupported();

  @override
  Future<void> notify(String title, String body, String? chatId) async {}

  @override
  Unsub on(String event, void Function(Map<String, Object?> data) cb) {
    (_listeners[event] ??= []).add(cb);
    return () => _listeners[event]?.remove(cb);
  }
}
