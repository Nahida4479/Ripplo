import 'dart:convert';

import '../util/js_compat.dart' as js;

const _backoffKey = 'gh:backoff';
const _fallbackBackoff = 15 * 60 * 1000;
const _minBackoff = 60 * 1000;

abstract class GhStorage {
  String? getItem(String key);
  void setItem(String key, String value);
}

class GhResponse {
  GhResponse(this.status, {this.headers = const {}, this.json});
  final int status;
  final Map<String, String> headers;
  final Future<Object?> Function()? json;
  bool get ok => status >= 200 && status < 300;
  String? header(String name) => headers[name.toLowerCase()];
}

class GhError implements Exception {
  GhError(this.message, {this.code, this.until});
  final String message;
  final String? code;
  final int? until;
  @override
  String toString() => message;
}

typedef GhFetch =
    Future<GhResponse> Function(String url, Map<String, String> headers);
typedef GhGet = Future<Object?> Function(String url, {int? maxAge});

num _number(String? s) {
  if (s == null) return 0;
  final t = s.trim();
  return t.isEmpty ? 0 : (num.tryParse(t) ?? double.nan);
}

GhGet createGithub({
  required GhFetch fetchFn,
  required GhStorage storage,
  int Function()? now,
  int ttl = 30 * 60 * 1000,
}) {
  int clock() => (now ?? js.now)();

  Map<String, Object?>? read(String k) {
    try {
      final v = jsonDecode(storage.getItem(k) ?? 'null');
      return v is Map ? Map<String, Object?>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  void write(String k, Object? v) {
    try {
      storage.setItem(k, jsonEncode(v));
    } catch (_) {}
  }

  GhError rate(int until) => GhError('rate', code: 'rate', until: until);

  return (String url, {int? maxAge}) async {
    final limit = maxAge ?? ttl;
    final key = 'gh:$url';
    final cached = read(key);
    final at = cached?['at'];
    if (cached != null && at is num && clock() - at < limit) {
      return cached['body'];
    }
    final until = _number(storage.getItem(_backoffKey));
    if (until > clock()) {
      if (cached != null) return cached['body'];
      throw rate(until.toInt());
    }
    final etag = cached?['etag'];
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      if (js.truthy(etag)) 'If-None-Match': '$etag',
    };
    final r = await fetchFn(url, headers);
    if (r.status == 304 && cached != null) {
      write(key, {...cached, 'at': clock()});
      return cached['body'];
    }
    if (r.status == 403 || r.status == 429) {
      final reset = _number(r.header('x-ratelimit-reset')) * 1000;
      final base = reset.isFinite && reset > 0
          ? reset
          : clock() + _fallbackBackoff;
      final wait = (base > clock() + _minBackoff ? base : clock() + _minBackoff)
          .toInt();
      try {
        storage.setItem(_backoffKey, '$wait');
      } catch (_) {}
      if (cached != null) return cached['body'];
      throw rate(wait);
    }
    if (!r.ok) throw GhError('${r.status}');
    final body = await r.json!();
    write(key, {'etag': r.header('etag'), 'body': body, 'at': clock()});
    return body;
  };
}
