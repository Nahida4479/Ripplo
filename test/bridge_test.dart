import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/mesh/native_mesh_bridge.dart';
import 'package:ripplo/util/byte_encoding.dart';

const codec = JSONMethodCodec();
const channel = MethodChannel('ripplo/mesh', codec);
const events = EventChannel('ripplo/mesh/events', codec);

final calls = <MethodCall>[];
Object? Function(MethodCall) handler = (_) => null;

Future<Object?> serve(MethodCall c) async {
  calls.add(c);
  final r = handler(c);
  if (r is Exception) throw r;
  return r;
}

void respond(Object? Function(MethodCall) h) => handler = h;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bridge = MeshBridge();
  final bytes = Uint8List.fromList([1, 2, 250, 255]);
  final enc = b64(bytes);

  setUp(() {
    calls.clear();
    handler = (_) => null;
    messenger.setMockMethodCallHandler(channel, serve);
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Map<String, dynamic> args() => Map<String, dynamic>.from(calls.single.arguments as Map);

  test('flags', () {
    expect(bridge.isNative, isTrue);
    expect(bridge.devCrypto, isFalse);
  });

  test('signal methods encode base64 and decode results', () async {
    respond((c) => {'bundle': enc, 'ik': enc});
    final i = await bridge.signalInit();
    expect(i.bundle, bytes);
    expect(i.ik, bytes);
    expect(calls.single.method, 'signalInit');

    calls.clear();
    respond((c) => {'tag': 'ab'});
    expect(await bridge.signalAddContact(bytes), 'ab');
    expect(calls.single.method, 'signalAddContact');
    expect(args(), {'bundle': enc});

    calls.clear();
    respond((c) => {'payload': enc});
    expect(await bridge.signalSeal('ab', bytes), bytes);
    expect(args(), {'tag': 'ab', 'plaintext': enc});

    calls.clear();
    respond((c) => {'tag': 'cd', 'ik': enc, 'plaintext': enc});
    final o = await bridge.signalOpen(bytes);
    expect(o.tag, 'cd');
    expect(o.ik, bytes);
    expect(o.plaintext, bytes);
    expect(args(), {'payload': enc});

    calls.clear();
    respond((c) => {'mac': enc});
    final other = Uint8List.fromList([9]);
    expect(await bridge.signalProof(bytes, other, other, bytes), bytes);
    expect(args(), {'ik': enc, 'n': b64(other), 'challengerTag': b64(other), 'proverTag': enc});

    calls.clear();
    respond((c) => {'digits': '123'});
    expect(await bridge.signalSafetyNumber(bytes), '123');
    expect(args(), {'ik': enc});

    calls.clear();
    respond((c) => null);
    await bridge.signalForget('ab');
    expect(calls.single.method, 'signalForget');
    expect(args(), {'tag': 'ab'});
  });

  test('transport methods', () async {
    respond((c) => {'nodeTag': 'n1'});
    expect(await bridge.start(bytes), 'n1');
    expect(calls.single.method, 'start');
    expect(args(), {'selfTag': enc});

    calls.clear();
    respond((c) => {'neighbors': 3});
    expect(await bridge.send(bytes), 3);
    expect(args(), {'packet': enc});

    calls.clear();
    respond((c) => null);
    await bridge.sendApp('ff', bytes);
    expect(calls.single.method, 'sendApp');
    expect(args(), {'node': 'ff', 'payload': enc});

    calls.clear();
    respond((c) => {'neighbors': [{'node': 'a', 'kbps': 5}]});
    expect(await bridge.getNeighbors(), [{'node': 'a', 'kbps': 5}]);
    expect(calls.single.method, 'getNeighbors');

    calls.clear();
    respond((c) => {'transports': [{'name': 'ble'}]});
    expect(await bridge.getTransports(), [{'name': 'ble'}]);
    expect(calls.single.method, 'getTransports');
  });

  test('drainInbox maps packets and opened', () async {
    respond((c) => {
          'packets': [
            {'packet': enc, 'from': 'x'},
            {'opened': {'a': 1}},
          ]
        });
    final r = await bridge.drainInbox();
    expect(calls.single.method, 'drainInbox');
    final p = r[0] as InboxPacket;
    expect(p.packet, bytes);
    expect(p.from, 'x');
    expect((r[1] as InboxOpened).opened, {'a': 1});
  });

  test('fallbacks when the native call fails', () async {
    respond((c) => PlatformException(code: 'unimplemented'));
    expect(await bridge.getDiag(), '');
    expect(await bridge.usbLog('x'), isFalse);
    expect(await bridge.getTransports(), isEmpty);
    expect(await bridge.devConnect('n', 's'), isFalse);
    expect(await bridge.getDeviceInfo(), '');
    expect(await bridge.getBleCaps(), (coded: false, extended: false));
    expect(await bridge.isLocked(), isFalse);
    expect(await bridge.takeOpen(), isNull);
    expect(await bridge.fromPlay(), isFalse);
    expect(await bridge.takeShare(), isNull);
    await bridge.clearDiag();
    await bridge.devDisconnect('n', 'm');
    await bridge.keepAwake(true);
    await bridge.endLockedCall();
    await bridge.stopRing();
  });

  test('success values and encodings of guarded methods', () async {
    respond((c) => {'log': 'abc'});
    expect(await bridge.getDiag(), 'abc');
    respond((c) => {'usb': true});
    expect(await bridge.usbLog('hello'), isTrue);
    expect(calls.last.method, 'usbLog');
    expect(Map.from(calls.last.arguments as Map), {'text': 'hello'});
    respond((c) => {'started': true});
    expect(await bridge.devConnect('n', 's'), isTrue);
    expect(Map.from(calls.last.arguments as Map), {'node': 'n', 'spec': 's'});
    respond((c) => {'text': 'dev'});
    expect(await bridge.getDeviceInfo(), 'dev');
    respond((c) => {'coded': true, 'extended': false});
    expect(await bridge.getBleCaps(), (coded: true, extended: false));
    respond((c) => {'locked': true});
    expect(await bridge.isLocked(), isTrue);
    respond((c) => {'open': {'chatId': 'c'}});
    expect(await bridge.takeOpen(), {'chatId': 'c'});
    respond((c) => {});
    expect(await bridge.takeOpen(), isNull);
    respond((c) => {'play': true});
    expect(await bridge.fromPlay(), isTrue);
    respond((c) => {'share': {'kind': 'text', 'text': 't'}});
    expect(await bridge.takeShare(), {'kind': 'text', 'text': 't'});
    respond((c) => null);
    await bridge.devDisconnect('n', 'm');
    expect(calls.last.method, 'devDisconnect');
    expect(Map.from(calls.last.arguments as Map), {'node': 'n', 'medium': 'm'});
    await bridge.keepAwake(true);
    expect(calls.last.method, 'keepAwake');
    expect(Map.from(calls.last.arguments as Map), {'on': true});
    await bridge.endLockedCall();
    expect(calls.last.method, 'endLockedCall');
    await bridge.stopRing();
    expect(calls.last.method, 'stopRing');
    await bridge.clearDiag();
    expect(calls.last.method, 'clearDiag');
  });

  test('missing plugin is swallowed by the three unguarded methods', () async {
    messenger.setMockMethodCallHandler(channel, null);
    await bridge.requestFullScreen();
    await bridge.startRing();
    await bridge.setAutoUpdate(true);
  });

  test('other errors from the three unguarded methods propagate', () async {
    respond((c) => PlatformException(code: 'boom', message: 'bad'));
    await expectLater(bridge.startRing(), throwsA(isA<MeshError>().having((e) => e.code, 'code', 'boom')));
    await expectLater(bridge.requestFullScreen(), throwsA(isA<MeshError>()));
    await expectLater(bridge.setAutoUpdate(false), throwsA(isA<MeshError>()));
  });

  test('plain methods and their params', () async {
    respond((c) => null);
    await bridge.requestFullScreen();
    await bridge.startRing();
    await bridge.setAutoUpdate(true);
    await bridge.requestBatteryExemption();
    await bridge.installUpdate('https://x', 'ab', true);
    await bridge.setSecure(true);
    await bridge.backupDisable();
    expect(calls.map((c) => c.method), [
      'requestFullScreen',
      'startRing',
      'setAutoUpdate',
      'requestBatteryExemption',
      'installUpdate',
      'setSecure',
      'backupDisable',
    ]);
    expect(Map.from(calls[2].arguments as Map), {'enabled': true});
    expect(Map.from(calls[4].arguments as Map), {'url': 'https://x', 'sha256': 'ab', 'prompt': true});
    expect(Map.from(calls[5].arguments as Map), {'on': true});
  });

  test('misc results', () async {
    respond((c) => {'key': enc});
    final k = await bridge.getDbKey();
    expect(k.key, bytes);
    expect(k.insecure, false);
    respond((c) => {'sha256': 'aa'});
    expect(await bridge.selfHash(), 'aa');
    respond((c) => {'sha256': null});
    expect(await bridge.selfHash(), isNull);
    respond((c) => {'bluetooth': 'granted', 'wifi': 'prompt'});
    expect(await bridge.checkPermissions(), {'bluetooth': 'granted', 'wifi': 'prompt'});
    expect(await bridge.requestPermissions(), {'bluetooth': 'granted', 'wifi': 'prompt'});
    respond((c) => {'biometric': true, 'deviceCredential': false});
    expect(await bridge.authAvailable(), (biometric: true, deviceCredential: false));
    respond((c) => {'ok': true});
    expect(await bridge.authenticate('why'), isTrue);
    expect(Map.from(calls.last.arguments as Map), {'reason': 'why'});
    respond((c) => null);
    await bridge.notify('t', 'b', 'chat');
    expect(calls.last.method, 'notify');
    expect(Map.from(calls.last.arguments as Map), {'title': 't', 'body': 'b', 'chatId': 'chat'});
    await bridge.notify('t', 'b', null);
    expect(Map.from(calls.last.arguments as Map), {'title': 't', 'body': 'b'});
  });

  test('db methods', () async {
    respond((c) => null);
    await bridge.dbPut('s', 'k', 'i', bytes);
    expect(calls.last.method, 'dbPut');
    expect(Map.from(calls.last.arguments as Map), {'store': 's', 'key': 'k', 'idx': 'i', 'value': enc});
    await bridge.dbPut('s', 'k', null, bytes);
    expect(Map.from(calls.last.arguments as Map), {'store': 's', 'key': 'k', 'value': enc});
    await bridge.dbDel('s', 'k');
    expect(calls.last.method, 'dbDel');
    expect(Map.from(calls.last.arguments as Map), {'store': 's', 'key': 'k'});

    respond((c) => {'value': enc});
    expect(await bridge.dbGet('s', 'k'), bytes);
    respond((c) => {'value': null});
    expect(await bridge.dbGet('s', 'k'), isNull);

    respond((c) => {'keys': ['a', 'b']});
    expect(await bridge.dbKeys('s', prefix: 'p'), ['a', 'b']);
    expect(Map.from(calls.last.arguments as Map), {'store': 's', 'prefix': 'p'});
    await bridge.dbKeys('s');
    expect(Map.from(calls.last.arguments as Map), {'store': 's'});

    respond((c) => {'rows': [{'key': 'a', 'value': enc}]});
    var all = await bridge.dbAll('s');
    expect(all.single.$1, 'a');
    expect(all.single.$2, bytes);
    expect(calls.last.method, 'dbAll');
    all = await bridge.dbByIdx('s', 'i');
    expect(all.single.$1, 'a');
    expect(all.single.$2, bytes);
    expect(calls.last.method, 'dbByIdx');
    expect(Map.from(calls.last.arguments as Map), {'store': 's', 'idx': 'i'});
  });

  test('backup methods', () async {
    respond((c) => {'enabled': true, 'lastAt': 1, 'folder': null});
    expect(await bridge.backupStatus(), {'enabled': true, 'lastAt': 1, 'folder': null});
    respond((c) => {'code': 'abc'});
    expect(await bridge.backupEnable(), 'abc');
    expect(await bridge.backupShowCode(), 'abc');
    respond((c) => {'folder': 'f'});
    expect(await bridge.backupChooseFolder(), 'f');
    respond((c) => {'ok': true, 'name': 'n', 'size': 3});
    expect(await bridge.backupCreate('now', {'a': 1}), {'ok': true, 'name': 'n', 'size': 3});
    expect(calls.last.method, 'backupCreate');
    expect(Map.from(calls.last.arguments as Map), {'mode': 'now', 'meta': {'a': 1}});
    respond((c) => {'meta': {}});
    expect(await bridge.backupRestore('code'), {'meta': {}});
    expect(Map.from(calls.last.arguments as Map), {'code': 'code'});
  });

  test('errors become MeshError with details', () async {
    respond((c) => PlatformException(code: 'untrusted_identity', message: 'm', details: {'tag': 'ab'}));
    await expectLater(
      bridge.signalSeal('ab', bytes),
      throwsA(isA<MeshError>()
          .having((e) => e.code, 'code', 'untrusted_identity')
          .having((e) => e.data, 'data', {'tag': 'ab'})),
    );
  });

  test('events', () async {
    final got = <Map<String, Object?>>[];
    final neighbors = <Map<String, Object?>>[];
    late MockStreamHandlerEventSink sink;
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (a, s) => sink = s),
    );
    final off = bridge.on('packet', got.add);
    bridge.on('neighbor', neighbors.add);
    await Future<void>.delayed(Duration.zero);
    sink.success({'event': 'packet', 'data': {'packet': enc, 'from': 'x'}});
    sink.success({'event': 'neighbor', 'data': {'node': 'n', 'up': true, 'medium': 'ble', 'kbps': 5.5}});
    sink.success({'event': 'open', 'data': {}});
    await Future<void>.delayed(Duration.zero);
    expect(got.single['packet'], bytes);
    expect(got.single['from'], 'x');
    expect(neighbors.single, {'node': 'n', 'up': true, 'medium': 'ble', 'kbps': 5.5});
    off();
    sink.success({'event': 'packet', 'data': {'packet': enc, 'from': 'y'}});
    await Future<void>.delayed(Duration.zero);
    expect(got.length, 1);
  });
}
