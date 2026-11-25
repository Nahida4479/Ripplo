import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'ui/components/add_contact_sheet.dart';
import 'ui/components/app_icon.dart';
import 'ui/components/call_overlay.dart';
import 'ui/components/confirm_sheet.dart';
import 'ui/components/lock_overlay.dart';
import 'ui/components/new_chat_sheet.dart';
import 'ui/components/share_sheet.dart';
import 'core/app_state.dart';
import 'translations.dart';
import 'navigation_stack.dart';
import 'data/backup_metadata.dart';
import 'services/app_lock.dart';
import 'ui/theme.dart';
import 'services/app_updater.dart';
import 'ui/ui_request_state.dart';
import 'ui/shared_widgets.dart';
import 'util/avatar_image_processing.dart';
import 'util/js_compat.dart' as js;
import 'ui/views/conversation_view.dart';
import 'ui/views/chat_list_view.dart';
import 'ui/views/contact_profile_view.dart';
import 'ui/views/permissions_gate_view.dart';
import 'ui/views/onboarding_view.dart';
import 'ui/views/nearby_people_view.dart';
import 'ui/views/settings_view.dart';

Future<String?> pickAvatar() async {
  final f = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (f == null) return null;
  final bytes = await f.readAsBytes();
  return makeAvatar(bytes);
}

class RipploApp extends StatelessWidget {
  const RipploApp({
    super.key,
    required this.theme,
    required this.state,
    required this.lock,
    required this.router,
    this.granted = false,
    this.onGranted,
    this.onRestored,
    this.updater,
    this.live = true,
    this.onPickAvatar = pickAvatar,
  });

  final ThemeController theme;
  final RipploState state;
  final AppLock lock;
  final RipploRouter router;
  final bool granted;
  final Future<void> Function()? onGranted;
  final VoidCallback? onRestored;
  final Updater? updater;
  final bool live;
  final Future<String?> Function() onPickAvatar;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: theme,
    builder: (context, _) {
      final data = theme.themeData;
      return MaterialApp(
        title: 'Ripplo',
        debugShowCheckedModeBanner: false,
        theme: data,
        home: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: const Color(0x00000000),
            systemNavigationBarColor: const Color(0x00000000),
            statusBarIconBrightness: theme.isLight
                ? Brightness.dark
                : Brightness.light,
            systemNavigationBarIconBrightness: theme.isLight
                ? Brightness.dark
                : Brightness.light,
          ),
          child: Material(
            color: theme.colors.bg,
            child: _Shell(app: this),
          ),
        ),
      );
    },
  );
}

class _Shell extends StatefulWidget {
  const _Shell({required this.app});

  final RipploApp app;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  late bool _granted = widget.app.granted;

  RipploApp get _a => widget.app;
  RipploState get _state => _a.state;
  RipploRouter get _router => _a.router;

  Future<void> _grant() async {
    if (_granted) return;
    setState(() => _granted = true);
    await _a.onGranted?.call();
  }

  Widget _splash() => ScrollCenter(
    children: [Semantics(liveRegion: true, child: const Text('Ripplo…'))],
  );

  Widget _page() {
    final chat = _router.chatId;
    final contact = _router.contactId;
    final key = ValueKey(_router.location);
    if (chat != null) {
      return ChatView(
        key: key,
        id: chat,
        state: _state,
        live: _a.live,
        onBack: _router.back,
        onOpenContact: _router.contact,
      );
    }
    if (contact != null) {
      return ContactView(
        key: key,
        id: contact,
        state: _state,
        live: _a.live,
        onBack: _router.back,
        onDeleted: () => _router.replace('/'),
      );
    }
    switch (_router.location) {
      case '/people':
        return PeopleView(key: key, state: _state, live: _a.live);
      case '/settings':
        return SettingsView(
          key: key,
          theme: _a.theme,
          state: _state,
          backupMeta: () => backupMeta(_state, _state.update.current),
          onCheckUpdate: _a.updater == null
              ? null
              : (manual) => _a.updater!.checkUpdate(manual),
          onInstall: _a.updater?.install,
          onSetAppLock: (on) => _a.lock.setAppLock(on),
          onPickAvatar: _a.onPickAvatar,
        );
      default:
        return ChatsView(
          key: key,
          state: _state,
          onOpenSettings: () => _router.push('/settings'),
          onOpenChat: _router.chat,
        );
    }
  }

  Widget _tabs() => ListenableBuilder(
    listenable: locale,
    builder: (context, _) => RTabBar(
      navLabel: t('navigation'),
      alertLabel: t('attention'),
      current: _router.location,
      onSelect: _router.push,
      items: [
        RTabItem(path: '/', icon: LucideIcons.messageCircle, label: t('chats')),
        RTabItem(path: '/people', icon: LucideIcons.users, label: t('people')),
        RTabItem(
          path: '/settings',
          icon: LucideIcons.settings,
          label: t('settings'),
          alert:
              _state.update.available || _state.integrity.status == 'mismatch',
        ),
      ],
    ),
  );

  Widget _content() {
    if (!_granted) return GateView(onGranted: () => js.fire(_grant()));
    if (!_state.ready || _state.lockedCall) return _splash();
    if (_state.needsOnboarding) {
      return OnboardingView(onRestored: _a.onRestored);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        _page(),
        if (!_router.full) _tabs(),
        AddContactSheet(state: _state, onOpenContact: _router.contact),
        NewChatSheet(state: _state, onOpenChat: _router.chat),
        if (!_a.lock.locked)
          ShareSheet(state: _state, onOpenChat: _router.chat),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _router,
    builder: (context, _) => PopScope(
      canPop: !_router.canBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _router.back();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([_state, _a.lock, _router]),
            builder: (context, _) => _content(),
          ),
          ListenableBuilder(
            listenable: _state,
            builder: (context, _) => _state.lockedCall
                ? const SizedBox.shrink()
                : const ConfirmSheet(),
          ),
          ListenableBuilder(
            listenable: _state,
            builder: (context, _) => _state.ready
                ? CallOverlay(state: _state)
                : const SizedBox.shrink(),
          ),
          ListenableBuilder(
            listenable: Listenable.merge([_state, _a.lock]),
            builder: (context, _) => _a.lock.showLock
                ? LockOverlay(
                    busy: _a.lock.busy,
                    onUnlock: () => js.fire(_a.lock.unlock()),
                  )
                : const SizedBox.shrink(),
          ),
          ListenableBuilder(
            listenable: Listenable.merge([_state, ui]),
            builder: (context, _) => _state.lockedCall
                ? const SizedBox.shrink()
                : RToast(text: ui.toastText),
          ),
        ],
      ),
    ),
  );
}
