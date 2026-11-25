import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/services/scheduler.dart';
import 'package:ripplo/util/js.dart' as js;
import 'package:ripplo/util/schedule.dart';

void main() {
  final savedClock = js.now;
  var t = 0;
  var refreshes = 0;

  setUp(() {
    t = windowStart(1768438800000);
    refreshes = 0;
    js.now = () => t;
  });

  tearDownAll(() => js.now = savedClock);

  Scheduler build(RipploState s) => Scheduler(
    state: s,
    refreshPeople: () async {
      refreshes++;
    },
  );

  RipploState profiled({String tag = '00000000'}) => RipploState()..profile = {'tag': tag, 'ripploId': 'r', 'name': 'n'};

  test('refreshes people when the profile slot is due', () {
    build(profiled()).tick();
    expect(refreshes, 1);
  });

  test('does nothing without a profile', () {
    build(RipploState()).tick();
    expect(refreshes, 0);
  });

  test('does nothing while a refresh is already running', () {
    final s = profiled()..peopleRefreshing = true;
    build(s).tick();
    expect(refreshes, 0);
  });

  test('skips when refreshed less than the stale age ago', () {
    final s = profiled()..peopleRefreshedAt = t - 3600000;
    build(s).tick();
    expect(refreshes, 0);
  });

  test('skips outside the nightly window', () {
    t += windowMs;
    build(profiled()).tick();
    expect(refreshes, 0);
  });

  test('a tag with no hex slot never refreshes', () {
    build(profiled(tag: 'zzzzzzzz')).tick();
    expect(refreshes, 0);
  });

  test('the tick interval is one scheduler slot', () {
    expect(slotMs, 15000);
  });
}
