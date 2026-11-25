import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/util/github_cache.dart';

class MapStorage implements GhStorage {
  final m = <String, String>{};
  @override
  String? getItem(String k) => m[k];
  @override
  void setItem(String k, String v) => m[k] = v;
}

class BrokenStorage implements GhStorage {
  @override
  String? getItem(String k) => null;
  @override
  void setItem(String k, String v) => throw StateError('x');
}

GhResponse res(
  int status,
  Object? body, [
  Map<String, String> headers = const {},
]) => GhResponse(status, headers: headers, json: () async => body);

void main() {
  test('serves a fresh answer from the cache without asking again', () async {
    var calls = 0;
    var t = 1000;
    final get = createGithub(
      storage: MapStorage(),
      now: () => t,
      fetchFn: (u, h) async {
        calls++;
        return res(200, {'n': 1}, {'etag': 'e1'});
      },
    );
    expect(await get('u'), {'n': 1});
    t += 60000;
    expect(await get('u'), {'n': 1});
    expect(calls, 1);
  });

  test(
    'revalidates a stale answer with the etag and keeps it on 304',
    () async {
      final seen = <String?>[];
      var t = 1000;
      final get = createGithub(
        storage: MapStorage(),
        now: () => t,
        fetchFn: (u, h) async {
          seen.add(h['If-None-Match']);
          return seen.length == 1
              ? res(200, {'n': 1}, {'etag': 'e1'})
              : res(304, null);
        },
      );
      await get('u');
      t += 31 * 60000;
      expect(await get('u'), {'n': 1});
      expect(seen, [null, 'e1']);
    },
  );

  test(
    'stops asking after a 403 until the reset time and reports it',
    () async {
      var calls = 0;
      var t = 5000000;
      final reset = (t + 20 * 60000) ~/ 1000;
      final get = createGithub(
        storage: MapStorage(),
        now: () => t,
        fetchFn: (u, h) async {
          calls++;
          return res(403, {}, {'x-ratelimit-reset': '$reset'});
        },
      );
      await expectLater(
        get('u'),
        throwsA(
          isA<GhError>()
              .having((e) => e.code, 'code', 'rate')
              .having((e) => e.until, 'until', reset * 1000),
        ),
      );
      await expectLater(
        get('u2'),
        throwsA(isA<GhError>().having((e) => e.code, 'code', 'rate')),
      );
      expect(calls, 1);
      t = reset * 1000 + 1;
      await expectLater(
        get('u'),
        throwsA(isA<GhError>().having((e) => e.code, 'code', 'rate')),
      );
      expect(calls, 2);
    },
  );

  test(
    'falls back to the cached answer when limited, and reports other errors as their status',
    () async {
      var t = 1000;
      var mode = 'ok';
      final get = createGithub(
        storage: MapStorage(),
        now: () => t,
        fetchFn: (u, h) async => mode == 'ok'
            ? res(200, {'n': 1})
            : mode == 'limit'
            ? res(403, {})
            : res(500, {}),
      );
      await get('u');
      t += 40 * 60000;
      mode = 'limit';
      expect(await get('u'), {'n': 1});
      final other = createGithub(
        storage: MapStorage(),
        fetchFn: (u, h) async => res(500, {}),
      );
      await expectLater(
        other('x'),
        throwsA(predicate((e) => e.toString().contains('500'))),
      );
    },
  );

  test('works without usable storage', () async {
    final get = createGithub(
      storage: BrokenStorage(),
      fetchFn: (u, h) async => res(200, {'ok': 1}),
    );
    expect(await get('u'), {'ok': 1});
  });

  test('vector script', () async {
    final v =
        (jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
                as Map)['githubCache']
            as Map;
    final script = (v['script'] as List).cast<Map>();
    final calls = <Map<String, Object?>>[];
    final storage = MapStorage();
    var t = 0;
    var next = 0;
    final get = createGithub(
      storage: storage,
      now: () => t,
      fetchFn: (url, headers) async {
        calls.add({'url': url, 'headers': Map<String, String>.from(headers)});
        final s = script[next++];
        return res(
          s['status'] as int,
          s['body'],
          Map<String, String>.from((s['headers'] as Map?) ?? {}),
        );
      },
    );
    for (final step in v['steps'] as List) {
      t = step['t'] as int;
      final opts = step['opts'] as Map?;
      Object? result;
      try {
        result = await get(
          step['url'] as String,
          maxAge: opts?['maxAge'] as int?,
        );
      } on GhError catch (e) {
        result = {'error': e.message};
      }
      expect(result, step['result'], reason: '${step['label']}');
      expect(calls.length, step['calls'], reason: '${step['label']}');
      expect(storage.m, step['storage'], reason: '${step['label']}');
    }
    expect(calls, v['calls']);
  });
}
