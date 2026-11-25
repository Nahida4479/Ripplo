import 'package:flutter/foundation.dart';

class RipploRouter extends ChangeNotifier {
  RipploRouter([String start = '/']) : _stack = [start];

  final List<String> _stack;

  String get location => _stack.last;
  bool get canBack => _stack.length > 1;
  bool get full => chatId != null || contactId != null;
  String? get chatId => _id('/chat/');
  String? get contactId => _id('/contact/');

  String? _id(String prefix) {
    final l = location;
    return l.startsWith(prefix) && l.length > prefix.length
        ? l.substring(prefix.length)
        : null;
  }

  void push(String to) {
    if (to == location) return;
    _stack.add(to);
    notifyListeners();
  }

  void replace(String to) {
    _stack[_stack.length - 1] = to;
    notifyListeners();
  }

  void back() {
    if (canBack) {
      _stack.removeLast();
    } else if (location != '/') {
      _stack[0] = '/';
    } else {
      return;
    }
    notifyListeners();
  }

  void chat(String id) => push('/chat/$id');
  void contact(String id) => push('/contact/$id');
}
