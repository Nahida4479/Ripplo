import 'package:ripplo/mesh/bridge.dart';

class SecMesh implements Mesh {
  SecMesh({this.isNative = true});

  @override
  final bool isNative;
  @override
  bool get devCrypto => false;

  bool authResult = true;
  bool locked = false;
  bool played = false;
  String? hash;
  Object? installError;
  Map<String, Object?>? open;
  final installs = <(String, String, bool)>[];
  final calls = <String>[];
  final secure = <bool>[];
  final handlers = <String, void Function(Map<String, Object?>)>{};

  @override
  Future<bool> authenticate(String reason) async {
    calls.add('auth');
    return authResult;
  }

  @override
  Future<void> setSecure(bool on) async => secure.add(on);

  @override
  Future<bool> isLocked() async => locked;

  @override
  Future<void> endLockedCall() async => calls.add('endLockedCall');

  @override
  Future<Map<String, Object?>?> takeOpen() async {
    final o = open;
    open = null;
    return o;
  }

  @override
  Future<String?> selfHash() async => hash;

  @override
  Future<bool> fromPlay() async => played;

  @override
  Future<void> setAutoUpdate(bool enabled) async => calls.add('auto:$enabled');

  @override
  Future<void> installUpdate(String url, String sha256, bool prompt) async {
    installs.add((url, sha256, prompt));
    if (installError != null) throw installError!;
  }

  @override
  Future<void> startRing() async => calls.add('startRing');

  @override
  Future<void> stopRing() async => calls.add('stopRing');

  @override
  Unsub on(String event, void Function(Map<String, Object?> data) cb) {
    handlers[event] = cb;
    return () => handlers.remove(event);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
