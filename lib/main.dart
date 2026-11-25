import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app.dart';
import 'core/api.dart' as api;
import 'core/call_audio.dart';
import 'i18n.dart';
import 'mesh/bridge.dart';
import 'mesh/dev_mesh.dart';
import 'router.dart';
import 'services/backup.dart';
import 'services/deep_link.dart';
import 'services/lock.dart';
import 'services/media_files.dart';
import 'services/notifications.dart';
import 'services/open_intent.dart';
import 'services/prefs.dart';
import 'services/scheduler.dart';
import 'services/share.dart';
import 'services/theme.dart';
import 'services/updater.dart';
import 'ui/ui_state.dart';
import 'util/github_cache.dart';
import 'util/js.dart' as js;

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
