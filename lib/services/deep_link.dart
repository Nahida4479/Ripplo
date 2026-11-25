import 'dart:async';

import 'package:app_links/app_links.dart';

import '../core/state.dart';
import '../crypto/identity.dart';
import '../i18n.dart';
import '../ui/ui_state.dart';
import '../util/js.dart' as js;

const _prefix = 'ripplo://add/';

class DeepLinks {
  DeepLinks({
    required this.state,
    required this.ui,
    required this.add,
    required this.openContact,
  });

  final RipploState state;
  final UiState ui;
  final Future<Contact?> Function(String url) add;
  final void Function(String id) openContact;
  String? _pending;
  StreamSubscription<Uri>? _sub;

  bool get _usable => state.ready && !state.needsOnboarding;

  void handle(String url) {
    if (!url.startsWith(_prefix)) return;
    if (_usable) {
      _ask(url);
    } else {
      _pending = url;
    }
  }

  void _onState() {
    final url = _pending;
    if (url == null || !_usable) return;
    _pending = null;
    _ask(url);
  }

  void _ask(String url) {
    ui.confirm = ConfirmRequest(
      title: t('addContact'),
      text: t('deepLinkConfirm'),
      ok: t('add'),
      onOk: () async {
        try {
          final c = await add(url);
          if (c != null) openContact(c.id);
        } catch (e) {
          ui.toast(t('err_${e is RipploError ? e.code : 'bad_link'}'));
        }
      },
    );
  }

  Future<void> _initial(AppLinks links) async {
    try {
      final u = await links.getInitialLink();
      if (u != null) handle('$u');
    } catch (_) {}
  }

  void start([AppLinks? links]) {
    state.addListener(_onState);
    try {
      final l = links ?? AppLinks();
      js.fire(_initial(l));
      _sub = l.uriLinkStream.listen(
        (u) => handle('$u'),
        onError: (Object _) {},
      );
    } catch (_) {}
  }

  void dispose() {
    state.removeListener(_onState);
    _sub?.cancel();
  }
}
