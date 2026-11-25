import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/contributor_logins.dart';
import 'package:ripplo/translations.dart';

final _plural = RegExp(r'_(zero|one|two|few|many|other)$');
final _ph = RegExp(r'\{(\w+)\}');

String _base(String k) => k.replaceFirst(_plural, '');

void main() {
  final en = i18nTable('en');
  final pl = i18nTable('pl');

  test('key sets match apart from plural categories', () {
    expect(en.length, 307);
    expect(pl.length, 309);
    final enBase = en.keys.map(_base).toSet();
    final plBase = pl.keys.map(_base).toSet();
    expect(plBase, enBase);
    expect(
      en.keys.where((k) => !_plural.hasMatch(k)).toSet(),
      pl.keys.where((k) => !_plural.hasMatch(k)).toSet(),
    );
  });

  test('empty values only where JS has them', () {
    expect(en.entries.where((e) => e.value.isEmpty).map((e) => e.key).toSet(), {
      'method_none',
      'status_received',
    });
    expect(pl.entries.where((e) => e.value.isEmpty).map((e) => e.key).toSet(), {
      'nextTonight',
      'method_none',
      'status_received',
    });
  });

  test('every EN placeholder appears in PL', () {
    for (final e in en.entries) {
      final pk = pl.containsKey(e.key) ? e.key : null;
      if (pk == null) continue;
      final enPh = _ph.allMatches(e.value).map((m) => m[1]).toSet();
      final plPh = _ph.allMatches(pl[pk]!).map((m) => m[1]).toSet();
      expect(plPh.containsAll(enPh), isTrue, reason: e.key);
    }
  });

  test('t interpolates, falls back and pluralises', () {
    setLocale('en');
    expect(t('nope_key'), 'nope_key');
    expect(t('undecryptable', {'name': 'Ann'}), contains('Ann'));
    expect(t('undecryptable'), isNot(contains('{')));
    expect(t('hops', {'n': 1}), en['hops_one']!.replaceAll('{n}', '1'));
    expect(t('hops', {'n': 3}), en['hops_other']!.replaceAll('{n}', '3'));
    setLocale('pl');
    expect(pluralCategory('pl', 1), 'one');
    expect(pluralCategory('pl', 3), 'few');
    expect(pluralCategory('pl', 12), 'many');
    expect(pluralCategory('pl', 22), 'few');
    expect(pluralCategory('pl', 0), 'many');
    expect(pluralCategory('pl', 1.5), 'other');
    expect(t('hops', {'n': 3}), pl['hops_few']!.replaceAll('{n}', '3'));
    expect(t('chats'), pl['chats']);
    setLocale('en');
  });

  test('contributors', () {
    expect(contributors, [
      {'login': 'Nahida4479'},
    ]);
  });
}
