import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_shell.dart';
import 'core/app_instances.dart' as api;
import 'core/call_audio_engine.dart';
import 'translations.dart';
import 'mesh/native_mesh_bridge.dart';
import 'mesh/dev/desktop_loopback_mesh.dart';
import 'navigation_stack.dart';
import 'data/backup_metadata.dart';
import 'services/deep_link_handler.dart';
import 'services/app_lock.dart';
import 'data/attachment_file_cache.dart';
import 'services/local_notifications.dart';
import 'services/notification_open_intent.dart';
import 'data/theme_language_prefs.dart';
import 'services/people_refresh_scheduler.dart';
import 'services/incoming_share_check.dart';
import 'ui/theme.dart';
import 'services/app_updater.dart';
import 'ui/ui_request_state.dart';
import 'data/github_api_cache.dart';
import 'util/js_compat.dart' as js;

Mesh _pickMesh() {
  final native =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  return native || kReleaseMode ? MeshBridge() : DevMesh();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await Prefs.load();
  final theme = await ThemeController.load(prefs);
  theme.attach();
  await initLocale(prefs);
  await wipeMediaCache();
  await prepareAudio();
  mesh = _pickMesh();

  final state = api.state;
  final router = RipploRouter();
  final notifications = Notifications(mesh: mesh);
  api.notifySink = notifications.notifier;
  router.addListener(() {
    final id = router.chatId;
    notifications.setOpenChat(id);
  });

  final lock = AppLock(
    mesh: mesh,
    state: state,
    saveSettings: api.saveSettings,
  );
  final updater = Updater(
    mesh: mesh,
    state: state,
    ui: ui,
    native: mesh.isNative,
    getJson: createGithub(
      fetchFn: httpGhFetch,
      storage: PrefsGhStorage(await SharedPreferences.getInstance()),
    ),
    openUrl: (u) =>
        js.fire(launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication)),
  );
  final scheduler = Scheduler(state: state, refreshPeople: api.refreshPeople);
  final openIntent = OpenIntent(
    mesh: mesh,
    state: state,
    acceptCall: api.acceptCall,
    openChat: router.chat,
    notifications: notifications,
  );
  final links = DeepLinks(
    state: state,
    ui: ui,
    add: (url) => api.addContactFromLink(url, 'link'),
    openContact: router.contact,
  );

  Future<void> start() async {
    await api.init();
    js.fire(updater.start());
    scheduler.start();
    lock.start();
    startBackup(mesh, state, await updater.version());
    startShare(mesh, ui);
    openIntent.start();
    links.start();
  }

  Future<void> restart() async {
    await api.core.close();
    await api.init();
  }

  runApp(
    RipploApp(
      theme: theme,
      state: state,
      lock: lock,
      router: router,
      updater: updater,
      onGranted: start,
      onRestored: () => js.fire(restart()),
    ),
  );
}
