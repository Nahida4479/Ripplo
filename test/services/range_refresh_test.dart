import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/app_state.dart';
import 'package:ripplo/services/neighbor_range_refresh.dart';
import 'package:ripplo/util/js_compat.dart' as js;

import 'fake_mesh.dart';

var clock = 1000000000;

void main() {
  setUp(() {
    clock += 3600000;
    js.now = () => clock;
  });

  test('updates links and seen only of matching neighbours', () async {
    final state = RipploState()
      ..neighbors = [
        {'node': 'a', 'links': 1, 'seen': 'x'},
        {'node': 'b', 'links': 2, 'seen': 'y'},
      ];
    final m = FakeMesh()
      ..neighbors = [
        {'node': 'b', 'links': 5, 'seen': 'z'},
        {'node': 'zz', 'links': 9, 'seen': 'q'},
      ];
    await refreshRange(mesh: m, state: state);
    expect(state.neighbors[0]['links'], 1);
    expect(state.neighbors[1]['links'], 5);
    expect(state.neighbors[1]['seen'], 'z');
    expect(state.neighbors.length, 2);
  });

  test('at most two refreshes in any ten second span', () async {
    final m = FakeMesh();
    final state = RipploState();
    for (var i = 0; i < 3; i++) {
      await refreshRange(mesh: m, state: state);
    }
    expect(m.calls.where((c) => c == 'getNeighbors').length, 2);
  });

  test('window reopens only after more than ten seconds', () async {
    final m = FakeMesh();
    final state = RipploState();
    await refreshRange(mesh: m, state: state);
    await refreshRange(mesh: m, state: state);
    clock += rangeWindowMs;
    await refreshRange(mesh: m, state: state);
    expect(m.calls.where((c) => c == 'getNeighbors').length, 2);
    clock += 1;
    await refreshRange(mesh: m, state: state);
    expect(m.calls.where((c) => c == 'getNeighbors').length, 3);
  });

  test('a failing neighbour lookup is swallowed', () async {
    final m = FakeMesh()..neighborsError = StateError('down');
    await refreshRange(mesh: m, state: RipploState());
    expect(m.calls, ['getNeighbors']);
  });
}
