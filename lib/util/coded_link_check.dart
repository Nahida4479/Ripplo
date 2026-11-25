import 'js_compat.dart';

bool isCodedLink(Object? l) {
  final medium = l is Map ? l['medium'] : null;
  final note = l is Map ? l['note'] : null;
  return const ['ble', 'l2cap'].contains('$medium'.toLowerCase()) &&
      '${truthy(note) ? note : ''}'.contains('coded');
}
