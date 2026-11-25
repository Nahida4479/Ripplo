import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/app_state.dart';
import 'package:ripplo/services/deep_link_handler.dart';
import 'package:ripplo/ui/ui_request_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('links wait for a ready profile and then ask for confirmation', () {
    final state = RipploState();
    final u = UiState();
    final links = DeepLinks(
      state: state,
      ui: u,
      add: (_) async => null,
      openContact: (_) {},
    );
    links.start();
    links.handle('https://example.com/x');
    links.handle('ripplo://add/abc');
    expect(u.confirm, isNull);
    state.ready = true;
    state.needsOnboarding = false;
    return Future<void>.delayed(Duration.zero).then((_) {
      expect(u.confirm, isNotNull);
      links.dispose();
    });
  });
}
