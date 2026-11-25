import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/mesh/bridge.dart';
import 'package:ripplo/services/updater.dart';
import 'package:ripplo/ui/ui_state.dart';
import 'package:ripplo/util/github_cache.dart';

import 'sec_mesh.dart';

final hex = 'a' * 64;
const apk =
    'https://github.com/Nahida4479/Ripplo/releases/download/v1.2.3/Ripplo-v1.2.3.apk';

Map<String, Object?> release({
  String? digest,
  String body = '',
  String url = apk,
}) => {
  'tag_name': 'v1.2.3',
  'html_url': 'https://github.com/Nahida4479/Ripplo/releases/tag/v1.2.3',
  'body': body,
  'assets': [
    {
      'name': 'Ripplo-v1.2.3.apk',
      'browser_download_url': url,
      'digest': ?digest,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecMesh mesh;
  late RipploState state;
  late UiState ui;
  late Object? Function(String url) respond;
  late bool online;
  late int clock;

  Updater make({bool native = true, String version = '1.0.0'}) => Updater(
    mesh: mesh,
    state: state,
    ui: ui,
    native: native,
    getJson: (url, {maxAge}) async => respond(url),
    currentVersion: () async => version,
    online: () => online,
    minCheck: Duration.zero,
    now: () => clock,
  );

  setUp(() {
    mesh = SecMesh();
    state = RipploState();
    ui = UiState();
    online = true;
    clock = 10 * 3600 * 1000;
    respond = (_) => release(digest: 'sha256:$hex');
  });

  test('newer compares numerically and ignores v prefix', () {
    expect(newer('1.10.0', '1.9.9'), isTrue);
    expect(newer('v2.0.0', '1.99.99'), isTrue);
    expect(newer('1.0.0', '1.0.0'), isFalse);
    expect(newer('1.0.0', '1.0.1'), isFalse);
    expect(newer('1.0', '1.0.0'), isFalse);
    expect(newer('1.0.1', '1.0'), isTrue);
  });

  test('hashOf prefers digest then body line', () {
    expect(hashOf(release(digest: 'sha256:$hex'), 'Ripplo-v1.2.3.apk'), hex);
    expect(
      hashOf(
        release(body: 'x\n  ${'b' * 64}  Ripplo-v1.2.3.apk\n'),
        'Ripplo-v1.2.3.apk',
      ),
      'b' * 64,
    );
    expect(
      hashOf(
        release(body: '${'b' * 63} Ripplo-v1.2.3.apk'),
        'Ripplo-v1.2.3.apk',
      ),
      isNull,
    );
    expect(hashOf(release(), 'Ripplo-v1.2.3.apk'), isNull);
  });

  test('checkUpdate sets state and prompts', () async {
    await make().checkUpdate();
    expect(state.update.available, isTrue);
    expect(state.update.latest, '1.2.3');
    expect(state.update.apkUrl, apk);
    expect(state.update.sha256, hex);
    expect(state.update.checking, isFalse);
    expect(ui.confirm, isNotNull);
  });

  test('no update when current is latest', () async {
    await make(version: '1.2.3').checkUpdate();
    expect(state.update.available, isFalse);
    expect(ui.confirm, isNull);
  });

  test('prompt is rate limited', () async {
    final u = make();
    await u.checkUpdate();
    ui.confirm = null;
    await u.checkUpdate();
    expect(ui.confirm, isNull);
    clock += 7 * 3600 * 1000;
    await u.checkUpdate();
    expect(ui.confirm, isNotNull);
  });

  test('offline skips check, errors reported', () async {
    online = false;
    await make().checkUpdate();
    expect(state.update.latest, isNull);
    online = true;
    respond = (_) => throw GhError('503');
    await make().checkUpdate();
    expect(state.update.error, '503');
  });

  test('install gating rejects non-https and bad hash', () async {
    respond = (_) =>
        release(digest: 'sha256:$hex', url: 'http://evil.test/a.apk');
    final u = make();
    await u.checkUpdate();
    await u.install();
    expect(mesh.installs, isEmpty);
    expect(state.update.error, isNotNull);
    respond = (_) => release(digest: 'sha256:zz');
    await u.checkUpdate();
    await u.install();
    expect(mesh.installs, isEmpty);
  });

  test('install passes verified url and sha', () async {
    final u = make();
    await u.checkUpdate();
    await u.install(false);
    expect(mesh.installs, [(apk, hex, false)]);
    expect(state.update.installing, isFalse);
    expect(state.update.progress, isNull);
  });

  test('install error is surfaced', () async {
    mesh.installError = const MeshError('x', 'boom');
    final u = make();
    await u.checkUpdate();
    await u.install();
    expect(state.update.error, 'boom');
    expect(state.update.installing, isFalse);
  });

  test('web build opens release page instead of installing', () async {
    final opened = <String>[];
    final u = Updater(
      mesh: mesh,
      state: state,
      ui: ui,
      native: false,
      getJson: (url, {maxAge}) async => respond(url),
      currentVersion: () async => '1.0.0',
      openUrl: opened.add,
      minCheck: Duration.zero,
    );
    await u.checkUpdate();
    await ui.confirm!.onOk();
    expect(mesh.installs, isEmpty);
    expect(opened, hasLength(1));
  });

  test('integrity ok, mismatch, offline, unsupported', () async {
    mesh.hash = hex.toUpperCase();
    respond = (_) => release(digest: 'sha256:$hex');
    final u = make(version: '1.2.3');
    await u.checkIntegrity();
    expect(state.integrity.status, 'ok');
    mesh.hash = 'c' * 64;
    await u.checkIntegrity();
    expect(state.integrity.status, 'mismatch');
    respond = (_) => throw GhError('rate', code: 'rate', until: 1);
    await u.checkIntegrity();
    expect(state.integrity.status, 'offline');
    mesh.hash = null;
    await u.checkIntegrity();
    expect(state.integrity.status, 'unsupported');
    await make(native: false).checkIntegrity();
    expect(state.integrity.status, 'unsupported');
  });

  test('integrity offline when no network', () async {
    mesh.hash = hex;
    online = false;
    await make().checkIntegrity();
    expect(state.integrity.status, 'offline');
  });

  test('play build disables auto update and skips checks', () async {
    mesh.played = true;
    final u = make();
    await u.start();
    expect(state.fromPlay, isTrue);
    expect(state.integrity.status, 'unsupported');
    expect(mesh.calls, contains('auto:false'));
    expect(state.update.latest, isNull);
    u.dispose();
  });
}
