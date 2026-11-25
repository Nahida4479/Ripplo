import 'package:ripplo/mesh/bridge.dart';

class FakeMesh implements Mesh {
  FakeMesh({this.isNative = true});

  @override
  final bool isNative;

  @override
  bool get devCrypto => false;

  final calls = <String>[];
  final notified = <({String title, String body, String? chatId})>[];
  final created = <(String, Map<String, Object?>)>[];
  final _handlers = <String, void Function(Map<String, Object?>)>{};

  Map<String, Object?> backupStatusResult = {};
  Object? backupStatusError;
  Map<String, Object?>? takeOpenResult;
  Map<String, Object?>? takeShareResult;
  List<Map<String, Object?>> neighbors = [];
  Object? neighborsError;
  Map<String, String> permissions = {};
  Map<String, String> requested = {};

  @override
  Future<Map<String, Object?>> backupStatus() async {
    calls.add('backupStatus');
    if (backupStatusError != null) throw backupStatusError!;
    return backupStatusResult;
  }

  @override
  Future<Map<String, Object?>> backupCreate(String mode, Map<String, Object?> meta) async {
    created.add((mode, meta));
    return {};
  }

  @override
  Future<void> notify(String title, String body, String? chatId) async {
    calls.add('notify');
    notified.add((title: title, body: body, chatId: chatId));
  }

  @override
  Future<Map<String, Object?>?> takeOpen() async => takeOpenResult;

  @override
  Future<Map<String, Object?>?> takeShare() async => takeShareResult;

  @override
  Future<List<Map<String, Object?>>> getNeighbors() async {
    calls.add('getNeighbors');
    if (neighborsError != null) throw neighborsError!;
    return neighbors;
  }

  @override
  Future<Map<String, String>> checkPermissions() async {
    calls.add('check');
    return permissions;
  }

  @override
  Future<Map<String, String>> requestPermissions() async {
    calls.add('request');
    return requested;
  }

  @override
  Unsub on(String event, void Function(Map<String, Object?> data) cb) {
    _handlers[event] = cb;
    return () => _handlers.remove(event);
  }

  @override
  Future<void> setHello(String card, bool hidden) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
