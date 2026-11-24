import '../core/state.dart';
import '../mesh/bridge.dart';
import '../util/js.dart' as js;

const rangeWindowMs = 10000;
const rangeMax = 2;

final _stamps = <int>[];

Future<void> refreshRange({required Mesh mesh, required RipploState state}) async {
  final now = js.now();
  while (_stamps.isNotEmpty && now - _stamps.first > rangeWindowMs) {
    _stamps.removeAt(0);
  }
  if (_stamps.length >= rangeMax) return;
  _stamps.add(now);
  try {
    for (final f in await mesh.getNeighbors()) {
      for (final cur in state.neighbors) {
        if (cur.node == f['node']) {
          cur
            ..put('links', f['links'])
            ..put('seen', f['seen']);
          break;
        }
      }
    }
  } catch (_) {}
}
