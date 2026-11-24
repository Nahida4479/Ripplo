import 'dart:async';

import 'package:flutter/foundation.dart';

@immutable
class AddRequest {
  const AddRequest({this.mode = 'add', this.id});
  final String mode;
  final String? id;
  bool get verify => mode == 'verify';
}

@immutable
class ConfirmRequest {
  const ConfirmRequest({
    required this.title,
    required this.text,
    required this.ok,
    required this.onOk,
    this.cancel,
    this.danger = false,
  });
  final String title;
  final String text;
  final String ok;
  final String? cancel;
  final bool danger;
  final FutureOr<void> Function() onOk;
}

@immutable
class ShareRequest {
  const ShareRequest({required this.kind, this.text, this.path, this.mime});
  final String kind;
  final String? text;
  final String? path;
  final String? mime;
}

class UiState extends ChangeNotifier {
  static const Duration toastDuration = Duration(milliseconds: 3000);

  AddRequest? _add;
  String? _newChat;
  ConfirmRequest? _confirm;
  ShareRequest? _share;
  String _toastText = '';
  Timer? _timer;

  AddRequest? get add => _add;
  set add(AddRequest? v) => _set(() => _add = v);
  String? get newChat => _newChat;
  set newChat(String? v) => _set(() => _newChat = v);
  ConfirmRequest? get confirm => _confirm;
  set confirm(ConfirmRequest? v) => _set(() => _confirm = v);
  ShareRequest? get share => _share;
  set share(ShareRequest? v) => _set(() => _share = v);
  String get toastText => _toastText;
  set toastText(String v) => _set(() => _toastText = v);

  void toast(String text) {
    toastText = text;
    _timer?.cancel();
    _timer = Timer(toastDuration, () => toastText = '');
  }

  void reset() {
    _timer?.cancel();
    _add = null;
    _newChat = null;
    _confirm = null;
    _share = null;
    _toastText = '';
    notifyListeners();
  }

  void _set(void Function() f) {
    f();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final UiState ui = UiState();

void toast(String text) => ui.toast(text);
