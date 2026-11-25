import 'dart:async';

import 'package:flutter/services.dart';

import '../util/bytes.dart';

typedef Unsub = void Function();

sealed class InboxItem {
  const InboxItem();
}

final class InboxPacket extends InboxItem {
  const InboxPacket(this.packet, this.from);

  final Uint8List packet;
  final String from;
}

final class InboxOpened extends InboxItem {
  const InboxOpened(this.opened);

  final Map<String, Object?> opened;
}

class MeshError implements Exception {
  const MeshError(this.code, this.message, [this.data]);

  final String code;
  final String message;
  final Object? data;

  @override
  String toString() => 'MeshError($code): $message';
}

abstract interface class Mesh {
  bool get isNative;
  bool get devCrypto;
  Future<({Uint8List bundle, Uint8List ik})> signalInit();
  Future<String> signalAddContact(Uint8List bundle);
  Future<Uint8List> signalSeal(String tag, Uint8List plaintext);
  Future<({String tag, Uint8List ik, Uint8List plaintext})> signalOpen(
    Uint8List payload,
  );
  Future<Uint8List> signalProof(
    Uint8List ik,
    Uint8List n,
    Uint8List challengerTag,
    Uint8List proverTag,
  );
  Future<String> signalSafetyNumber(Uint8List ik);
  Future<void> signalForget(String tag);
  Future<String> start(Uint8List selfTag);
  Future<int> send(Uint8List packet);
  Future<void> sendApp(String node, Uint8List payload);
  Future<List<Map<String, Object?>>> getNeighbors();
  Future<String> getDiag();
  Future<void> clearDiag();
  Future<bool> usbLog(String text);
  Future<List<Map<String, Object?>>> getTransports();
  Future<bool> devConnect(String node, String spec);
  Future<void> devDisconnect(String node, String medium);
  Future<String> getDeviceInfo();
  Future<({bool coded, bool extended})> getBleCaps();
  Future<List<InboxItem>> drainInbox();
  Future<bool> isLocked();
  Future<void> keepAwake(bool on);
  Future<void> endLockedCall();
  Future<Map<String, Object?>?> takeOpen();
  Future<({Uint8List key, bool insecure})> getDbKey();
  Future<String?> selfHash();
  Future<bool> fromPlay();
  Future<void> installUpdate(String url, String sha256, bool prompt);
  Future<void> requestBatteryExemption();
  Future<void> setAutoUpdate(bool enabled);
  Future<void> requestFullScreen();
  Future<void> startRing();
  Future<void> stopRing();
  Future<Map<String, Object?>?> takeShare();
  Future<Map<String, String>> checkPermissions();
  Future<Map<String, String>> requestPermissions();
  Future<void> dbPut(String store, String key, String? idx, Uint8List value);
  Future<Uint8List?> dbGet(String store, String key);
  Future<void> dbDel(String store, String key);
  Future<List<String>> dbKeys(String store, {String? prefix});
  Future<List<(String, Uint8List)>> dbAll(String store);
  Future<List<(String, Uint8List)>> dbByIdx(String store, String idx);
  Future<({bool biometric, bool deviceCredential})> authAvailable();
  Future<bool> authenticate(String reason);
  Future<void> setSecure(bool on);
  Future<Map<String, Object?>> backupStatus();
  Future<String> backupEnable();
  Future<String> backupShowCode();
  Future<void> backupDisable();
  Future<String> backupChooseFolder();
  Future<Map<String, Object?>> backupCreate(
    String mode,
    Map<String, Object?> meta,
  );
  Future<Map<String, Object?>> backupRestore(String code);
  Future<void> notify(String title, String body, String? chatId);
  Unsub on(String event, void Function(Map<String, Object?> data) cb);
}

Map<String, Object?> _map(Object? v) => Map<String, Object?>.from(v as Map);

List<Map<String, Object?>> _maps(Object? v) => (v as List).map(_map).toList();

List<(String, Uint8List)> _rows(Object? v) => (v as List)
    .map((r) => ((r as Map)['key'] as String, unb64(r['value'] as String)))
    .toList();

Map<String, Object?> _inbound(Map<String, Object?> e) => {
  'packet': unb64(e['packet'] as String),
  'from': e['from'],
};

class MeshBridge implements Mesh {
  MeshBridge({MethodChannel? channel, EventChannel? events})
    : _ch = channel ?? const MethodChannel('ripplo/mesh', JSONMethodCodec()),
      _events =
          events ?? const EventChannel('ripplo/mesh/events', JSONMethodCodec());

  final MethodChannel _ch;
  final EventChannel _events;
  Stream<dynamic>? _stream;

  @override
  bool get isNative => true;

  @override
  bool get devCrypto => false;

  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<Object?>(
        method,
        args ?? <String, Object?>{},
      );
    } on PlatformException catch (e) {
      throw MeshError(e.code, e.message ?? e.code, e.details);
    }
  }

  Future<void> _ignore(String method, [Map<String, Object?>? args]) async {
    try {
      await _call(method, args);
    } catch (_) {
      return;
    }
  }

  Future<void> _unlessMissing(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      await _call(method, args);
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<({Uint8List bundle, Uint8List ik})> signalInit() async {
    final r = _map(await _call('signalInit'));
    return (bundle: unb64(r['bundle'] as String), ik: unb64(r['ik'] as String));
  }

  @override
  Future<String> signalAddContact(Uint8List bundle) async =>
      _map(await _call('signalAddContact', {'bundle': b64(bundle)}))['tag']
          as String;

  @override
  Future<Uint8List> signalSeal(String tag, Uint8List plaintext) async => unb64(
    _map(
          await _call('signalSeal', {'tag': tag, 'plaintext': b64(plaintext)}),
        )['payload']
        as String,
  );

  @override
  Future<({String tag, Uint8List ik, Uint8List plaintext})> signalOpen(
    Uint8List payload,
  ) async {
    final r = _map(await _call('signalOpen', {'payload': b64(payload)}));
    return (
      tag: r['tag'] as String,
      ik: unb64(r['ik'] as String),
      plaintext: unb64(r['plaintext'] as String),
    );
  }

  @override
  Future<Uint8List> signalProof(
    Uint8List ik,
    Uint8List n,
    Uint8List challengerTag,
    Uint8List proverTag,
  ) async {
    final r = await _call('signalProof', {
      'ik': b64(ik),
      'n': b64(n),
      'challengerTag': b64(challengerTag),
      'proverTag': b64(proverTag),
    });
    return unb64(_map(r)['mac'] as String);
  }

  @override
  Future<String> signalSafetyNumber(Uint8List ik) async =>
      _map(await _call('signalSafetyNumber', {'ik': b64(ik)}))['digits']
          as String;

  @override
  Future<void> signalForget(String tag) async {
    await _call('signalForget', {'tag': tag});
  }

  @override
  Future<String> start(Uint8List selfTag) async =>
      _map(await _call('start', {'selfTag': b64(selfTag)}))['nodeTag']
          as String;

  @override
  Future<int> send(Uint8List packet) async =>
      (_map(await _call('send', {'packet': b64(packet)}))['neighbors'] as num)
          .toInt();

  @override
  Future<void> sendApp(String node, Uint8List payload) async {
    await _call('sendApp', {'node': node, 'payload': b64(payload)});
  }

  @override
  Future<List<Map<String, Object?>>> getNeighbors() async =>
      _maps(_map(await _call('getNeighbors'))['neighbors']);

  @override
  Future<String> getDiag() async {
    try {
      return _map(await _call('getDiag'))['log'] as String;
    } catch (_) {
      return '';
    }
  }

  @override
  Future<void> clearDiag() => _ignore('clearDiag');

  @override
  Future<bool> usbLog(String text) async {
    try {
      return _map(await _call('usbLog', {'text': text}))['usb'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<Map<String, Object?>>> getTransports() async {
    try {
      return _maps(_map(await _call('getTransports'))['transports']);
    } catch (_) {
      return [];
    }
  }

  @override
  Future<bool> devConnect(String node, String spec) async {
    try {
      return _map(
            await _call('devConnect', {'node': node, 'spec': spec}),
          )['started'] ==
          true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> devDisconnect(String node, String medium) =>
      _ignore('devDisconnect', {'node': node, 'medium': medium});

  @override
  Future<String> getDeviceInfo() async {
    try {
      return _map(await _call('getDeviceInfo'))['text'] as String;
    } catch (_) {
      return '';
    }
  }

  @override
  Future<({bool coded, bool extended})> getBleCaps() async {
    try {
      final r = _map(await _call('getBleCaps'));
      return (coded: r['coded'] == true, extended: r['extended'] == true);
    } catch (_) {
      return (coded: false, extended: false);
    }
  }

  @override
  Future<List<InboxItem>> drainInbox() async {
    final list = _map(await _call('drainInbox'))['packets'] as List;
    return list.map<InboxItem>((e) {
      final m = _map(e);
      final o = m['opened'];
      if (o is Map) return InboxOpened(_map(o));
      return InboxPacket(unb64(m['packet'] as String), m['from'] as String);
    }).toList();
  }

  @override
  Future<bool> isLocked() async {
    try {
      return _map(await _call('isLocked'))['locked'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> keepAwake(bool on) => _ignore('keepAwake', {'on': on});

  @override
  Future<void> endLockedCall() => _ignore('endLockedCall');

  @override
  Future<Map<String, Object?>?> takeOpen() async {
    try {
      final o = _map(await _call('takeOpen'))['open'];
      return o is Map ? _map(o) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<({Uint8List key, bool insecure})> getDbKey() async => (
    key: unb64(_map(await _call('getDbKey'))['key'] as String),
    insecure: false,
  );

  @override
  Future<String?> selfHash() async =>
      _map(await _call('selfHash'))['sha256'] as String?;

  @override
  Future<bool> fromPlay() async {
    try {
      return _map(await _call('fromPlay'))['play'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> installUpdate(String url, String sha256, bool prompt) async {
    await _call('installUpdate', {
      'url': url,
      'sha256': sha256,
      'prompt': prompt,
    });
  }

  @override
  Future<void> requestBatteryExemption() async {
    await _call('requestBatteryExemption');
  }

  @override
  Future<void> setAutoUpdate(bool enabled) =>
      _unlessMissing('setAutoUpdate', {'enabled': enabled});

  @override
  Future<void> requestFullScreen() => _unlessMissing('requestFullScreen');

  @override
  Future<void> startRing() => _unlessMissing('startRing');

  @override
  Future<void> stopRing() => _ignore('stopRing');

  @override
  Future<Map<String, Object?>?> takeShare() async {
    try {
      final o = _map(await _call('takeShare'))['share'];
      return o is Map ? _map(o) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, String>> checkPermissions() async =>
      Map<String, String>.from(_map(await _call('checkPermissions')));

  @override
  Future<Map<String, String>> requestPermissions() async =>
      Map<String, String>.from(_map(await _call('requestPermissions')));

  @override
  Future<void> dbPut(
    String store,
    String key,
    String? idx,
    Uint8List value,
  ) async {
    await _call('dbPut', {
      'store': store,
      'key': key,
      'idx': ?idx,
      'value': b64(value),
    });
  }

  @override
  Future<Uint8List?> dbGet(String store, String key) async {
    final v = _map(await _call('dbGet', {'store': store, 'key': key}))['value'];
    return v == null ? null : unb64(v as String);
  }

  @override
  Future<void> dbDel(String store, String key) async {
    await _call('dbDel', {'store': store, 'key': key});
  }

  @override
  Future<List<String>> dbKeys(String store, {String? prefix}) async {
    final r = _map(await _call('dbKeys', {'store': store, 'prefix': ?prefix}));
    return List<String>.from(r['keys'] as List);
  }

  @override
  Future<List<(String, Uint8List)>> dbAll(String store) async =>
      _rows(_map(await _call('dbAll', {'store': store}))['rows']);

  @override
  Future<List<(String, Uint8List)>> dbByIdx(String store, String idx) async =>
      _rows(_map(await _call('dbByIdx', {'store': store, 'idx': idx}))['rows']);

  @override
  Future<({bool biometric, bool deviceCredential})> authAvailable() async {
    final r = _map(await _call('authAvailable'));
    return (
      biometric: r['biometric'] == true,
      deviceCredential: r['deviceCredential'] == true,
    );
  }

  @override
  Future<bool> authenticate(String reason) async =>
      _map(await _call('authenticate', {'reason': reason}))['ok'] == true;

  @override
  Future<void> setSecure(bool on) async {
    await _call('setSecure', {'on': on});
  }

  @override
  Future<Map<String, Object?>> backupStatus() async =>
      _map(await _call('backupStatus'));

  @override
  Future<String> backupEnable() async =>
      _map(await _call('backupEnable'))['code'] as String;

  @override
  Future<String> backupShowCode() async =>
      _map(await _call('backupShowCode'))['code'] as String;

  @override
  Future<void> backupDisable() async {
    await _call('backupDisable');
  }

  @override
  Future<String> backupChooseFolder() async =>
      _map(await _call('backupChooseFolder'))['folder'] as String;

  @override
  Future<Map<String, Object?>> backupCreate(
    String mode,
    Map<String, Object?> meta,
  ) async => _map(await _call('backupCreate', {'mode': mode, 'meta': meta}));

  @override
  Future<Map<String, Object?>> backupRestore(String code) async =>
      _map(await _call('backupRestore', {'code': code}));

  @override
  Future<void> notify(String title, String body, String? chatId) async {
    await _call('notify', {'title': title, 'body': body, 'chatId': ?chatId});
  }

  @override
  Unsub on(String event, void Function(Map<String, Object?> data) cb) {
    final sub = (_stream ??= _events.receiveBroadcastStream()).listen((e) {
      if (e is! Map || e['event'] != event) return;
      final d = e['data'];
      final data = d is Map ? _map(d) : <String, Object?>{};
      cb(event == 'packet' ? _inbound(data) : data);
    }, onError: (Object _) {});
    return () => unawaited(sub.cancel());
  }
}

late Mesh mesh;
