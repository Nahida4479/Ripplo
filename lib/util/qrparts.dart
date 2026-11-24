import 'package:crypto/crypto.dart';

import 'bytes.dart';
import 'js.dart';

const partSize = 420;
const _maxParts = 20;
const _maxSets = 4;
final _re = RegExp(
  r'^ripplo://p/([A-Za-z0-9_-]{8})\.(\d{1,2})\.(\d{1,2})\.(.+)$',
  dotAll: true,
);

String _setId(String link) =>
    b64url(sha256.convert(utf8(link)).bytes.sublist(0, 6));

List<String> splitLink(String link) {
  final total = (link.length / partSize).ceil();
  final id = _setId(link);
  return List.generate(
    total,
    (i) =>
        'ripplo://p/$id.${i + 1}.$total.${cut(link, i * partSize, (i + 1) * partSize)}',
  );
}

class _PartSet {
  _PartSet(this.total);
  final int total;
  final parts = <int, String>{};
}

class Assembler {
  final _sets = <String, _PartSet>{};

  Map<String, Object?>? add(Object? text) {
    final m = _re.firstMatch('$text'.trim());
    if (m == null) return null;
    final id = m.group(1)!;
    final index = int.parse(m.group(2)!);
    final total = int.parse(m.group(3)!);
    final data = m.group(4)!;
    if (total < 2 ||
        total > _maxParts ||
        index < 1 ||
        index > total ||
        data.length > partSize) {
      return {'ignored': true};
    }
    var set = _sets[id];
    if (set == null || set.total != total) {
      set = _PartSet(total);
      _sets[id] = set;
      if (_sets.length > _maxSets) _sets.remove(_sets.keys.first);
    }
    set.parts[index] = data;
    if (set.parts.length < total) {
      return {'have': set.parts.length, 'total': total};
    }
    _sets.remove(id);
    final link = List.generate(total, (k) => set!.parts[k + 1]).join();
    return _setId(link) == id ? {'link': link} : {'bad': true};
  }
}

Assembler createAssembler() => Assembler();
