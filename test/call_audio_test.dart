import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/call_audio.dart';
import 'package:ripplo/core/calls.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/crypto/call_frame.dart';
import 'package:ripplo/util/bytes.dart';

class FakeBackend implements CallAudioBackend {
  final ctl = StreamController<Uint8List>.broadcast();
  final played = <Uint8List>[];
  final mutes = <bool>[];
  var started = 0;
  var fallbacks = 0;
  var stopped = 0;
  var failStart = false;

  @override
  Stream<Uint8List> get pcm => ctl.stream;

  @override
  Future<void> start({required bool raw}) async {
    if (failStart) throw StateError('mic');
    started++;
  }

  @override
  Future<void> play(Uint8List pcm) async => played.add(pcm);

  @override
  Future<void> setMuted(bool on) async => mutes.add(on);

  @override
  Future<void> fallback() async => fallbacks++;

  @override
  Future<void> stop() async => stopped++;

  void emit(Int16List samples) => ctl.add(Uint8List.sublistView(samples));
}

class FakeEnc implements OpusEnc {
  FakeEnc(this.inputs);

  final List<Int16List> inputs;

  @override
  Uint8List encode(Int16List pcm) {
    inputs.add(Int16List.fromList(pcm));
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  void destroy() {}
}

class FakeDec implements OpusDec {
  FakeDec(this.level);

  final int Function() level;

  @override
  Int16List decode(Uint8List frame) {
    final out = Int16List(callFrame);
    out.fillRange(0, callFrame, level());
    return out;
  }

  @override
  void destroy() {}
}

Int16List constant(int v) => Int16List(callFrame)..fillRange(0, callFrame, v);

Int16List sine(int frame, double amp) {
  final out = Int16List(callFrame);
  for (var i = 0; i < callFrame; i++) {
    final t = (frame * callFrame + i) / callRate;
    out[i] = (math.sin(2 * math.pi * 440 * t) * amp * 32767).round();
  }
  return out;
}

OpusCodecs? loadSystemOpus() {
  try {
    return opusCodecsFor(DynamicLibrary.open('libopus.so.0'));
  } catch (_) {
    return null;
  }
}

void main() {
  group('opus', () {
    final codecs = loadSystemOpus();

    test('sine wave survives an encode decode round trip', () {
      final mic = FakeBackend();
      final speaker = FakeBackend();
      var t = 0;
      final tx = OpusCallAudio(mic, codecs: codecs, clockMs: () => t);
      final rx = OpusCallAudio(speaker, codecs: codecs, clockMs: () => t);
      final sent = <Uint8List>[];
      tx.start(sent.addAll).then((_) {});
      rx.start((_) {}).then((_) {});
      return Future(() async {
        await Future<void>.delayed(Duration.zero);
        for (var i = 0; i < 60; i++) {
          mic.emit(sine(i, 0.5));
          await Future<void>.delayed(Duration.zero);
        }
        expect(sent.length, 60 ~/ callBatch * callBatch);
        expect(sent.every((f) => f.length > 1 && f.length < 200), isTrue);
        for (final f in sent) {
          t += 20;
          rx.play([f]);
        }
        expect(speaker.played.length, sent.length);
        final all = BytesBuilder();
        for (final p in speaker.played.skip(10)) {
          all.add(p);
        }
        final pcm = all.toBytes().buffer.asInt16List();
        var crossings = 0;
        var energy = 0.0;
        var top = 0;
        for (var i = 1; i < pcm.length; i++) {
          if ((pcm[i - 1] < 0) != (pcm[i] < 0)) crossings++;
          energy += pcm[i] * pcm[i];
          top = math.max(top, pcm[i].abs());
        }
        final seconds = pcm.length / callRate;
        expect(crossings / seconds / 2, closeTo(440, 15));
        expect(top / 32768, inInclusiveRange(0.35, 0.7));
        expect(math.sqrt(energy / pcm.length) / 32768, closeTo(0.35, 0.08));
        final st = rx.stats();
        expect(st['out'] as double, greaterThan(0.35));
        expect(st['errors'], 0);
        tx.stop();
        rx.stop();
      });
    }, skip: codecs == null ? 'libopus.so.0 cannot be loaded in the test VM' : false);

    test('encoder runs at the configured bitrate', () {
      final enc = codecs!.encoder();
      var bytes = 0;
      for (var i = 0; i < 100; i++) {
        bytes += enc.encode(sine(i, 0.5)).length;
      }
      enc.destroy();
      final kbps = bytes * 8 / 2 / 1000;
      expect(kbps, inInclusiveRange(10, 22));
    }, skip: codecs == null ? 'libopus.so.0 cannot be loaded in the test VM' : false);
  });

  group('audio engine', () {
    late FakeBackend backend;
    late List<Int16List> inputs;
    late int clock;
    late int level;
    late OpusCallAudio audio;

    setUp(() {
      backend = FakeBackend();
      inputs = [];
      clock = 1000000;
      level = 8000;
      audio = OpusCallAudio(
        backend,
        codecs: OpusCodecs(() => FakeEnc(inputs), () => FakeDec(() => level)),
        clockMs: () => clock,
      );
    });

    Future<void> go(List<List<Uint8List>> sink) async {
      await audio.start(sink.add);
    }

    test('batches three frames per callback and counts them', () async {
      final sink = <List<Uint8List>>[];
      await go(sink);
      for (var i = 0; i < 7; i++) {
        backend.emit(constant(1000));
        await Future<void>.delayed(Duration.zero);
      }
      expect(sink.length, 2);
      expect(sink.every((b) => b.length == callBatch), isTrue);
      final st = audio.stats();
      expect(st['sent'], 6);
      expect(st['frames'], 7);
      expect(st['track'], 'live');
      expect(st['ctx'], 'running');
      audio.stop();
      expect(audio.stats()['track'], 'ended');
      expect(audio.stats()['ctx'], 'none');
    });

    test('mic peak is measured and reset on read', () async {
      await go([]);
      backend.emit(constant(16384));
      await Future<void>.delayed(Duration.zero);
      expect(audio.stats()['mic'], closeTo(0.5, 0.0001));
      expect(audio.stats()['mic'], 0);
      audio.stop();
    });

    test('jitter buffer plays 16 frames ahead of the clock and then drops', () async {
      await go([]);
      final frame = Uint8List.fromList([1]);
      for (var i = 0; i < 30; i++) {
        audio.play([frame]);
      }
      await Future<void>.delayed(Duration.zero);
      final st = audio.stats();
      expect(st['recv'], 30);
      expect(st['played'], 16);
      expect(backend.played.length, 16);
      expect(backend.played.first.length, callFrameBytes);
      expect(st['out'], closeTo(8000 / 32768, 0.0001));
      audio.stop();
    });

    test('jitter buffer re-primes after the clock passes the queue', () async {
      await go([]);
      final frame = Uint8List.fromList([1]);
      for (var i = 0; i < 30; i++) {
        audio.play([frame]);
      }
      clock += 5000;
      for (var i = 0; i < 5; i++) {
        audio.play([frame]);
      }
      await Future<void>.delayed(Duration.zero);
      expect(audio.stats()['played'], 21);
      audio.stop();
    });

    test('frames arriving at the real rate are never dropped', () async {
      await go([]);
      final frame = Uint8List.fromList([1]);
      for (var i = 0; i < 100; i++) {
        audio.play([frame]);
        clock += 20;
      }
      await Future<void>.delayed(Duration.zero);
      expect(audio.stats()['played'], 100);
      audio.stop();
    });

    test('play is ignored before start and after stop', () async {
      audio.play([Uint8List.fromList([1])]);
      expect(audio.stats()['recv'], 0);
      await go([]);
      audio.stop();
      audio.play([Uint8List.fromList([1])]);
      expect(audio.stats()['recv'], 0);
    });

    test('mute reaches the backend and silences what is encoded', () async {
      await go([]);
      audio.setMuted(true);
      backend.emit(constant(20000));
      await Future<void>.delayed(Duration.zero);
      expect(backend.mutes, [true]);
      expect(inputs.single.every((v) => v == 0), isTrue);
      expect(audio.stats()['frames'], 1);
      audio.setMuted(false);
      backend.emit(constant(20000));
      await Future<void>.delayed(Duration.zero);
      expect(backend.mutes, [true, false]);
      expect(inputs.last.every((v) => v == 20000), isTrue);
      audio.stop();
    });

    test('a wrong sized pcm event counts as an error', () async {
      await go([]);
      backend.emit(Int16List(10));
      await Future<void>.delayed(Duration.zero);
      expect(audio.stats()['errors'], 1);
      audio.stop();
    });

    test('start failure rethrows and leaves the engine unusable', () async {
      backend.failStart = true;
      await expectLater(go([]), throwsStateError);
      audio.play([Uint8List.fromList([1])]);
      expect(audio.stats()['recv'], 0);
    });

    test('fallback reaches the backend only while running', () async {
      await audio.fallback();
      expect(backend.fallbacks, 0);
      await go([]);
      await audio.fallback();
      expect(backend.fallbacks, 1);
      audio.stop();
      await audio.fallback();
      expect(backend.fallbacks, 1);
    });
  });

  group('call warnings', () {
    late RipploState state;
    late FakeBackend backend;
    late int incoming;
    late Calls calls;
    late List<Map<String, Object?>> signals;
    late Timer pump;
    var micLevel = 0;
    var seq = 0;
    var running = false;

    setUp(() {
      state = RipploState();
      backend = FakeBackend();
      signals = [];
      incoming = 0;
      micLevel = 0;
      seq = 0;
      running = false;
      calls = Calls(
        state: state,
        timing: {'warn': 1, 'silence': 60000, 'first': 60000, 'hold': 50},
        signal: (peer, body) async {
          signals.add(body);
          return true;
        },
        sendMedia: (peer, packet, node) => true,
        hasNeighbor: (peer, node) => true,
        supported: () => true,
        log: (peer, reason, ms) {},
        notify: (peer) {},
        newAudio: () async => OpusCallAudio(
          backend,
          codecs: OpusCodecs(
            () => FakeEnc([]),
            () => FakeDec(() => incoming),
          ),
        ),
      );
    });

    tearDown(() {
      if (running) pump.cancel();
      calls.hangup();
    });

    Future<void> connect() async {
      await calls.start('peer');
      final offer = signals.firstWhere((s) => s['k'] == 'offer');
      await calls.onSignal('peer', {'t': 'call', 'k': 'accept', 'id': offer['id']});
      expect(state.call!.status, 'active');
      final key = importCallKey(unb64(offer['key'] as String));
      final id = unb64(offer['id'] as String);
      pump = Timer.periodic(const Duration(milliseconds: 100), (_) async {
        backend.emit(constant(micLevel));
        if (incoming >= 0) {
          final packet = await sealFrame(
            key,
            id,
            1,
            seq++,
            packFrames([Uint8List.fromList([1, 2, 3])]),
          );
          await calls.onMedia(packet, 'n1');
        }
      });
      running = true;
    }

    test('silent microphone raises callWarn_mic and triggers the raw fallback', () async {
      micLevel = 0;
      incoming = 8000;
      await connect();
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(state.call!.warn, 'mic');
      expect(backend.fallbacks, 1);
      expect(state.call!.stats!['frames'], isNotNull);
    });

    test('loud microphone and silent incoming audio raises callWarn_out', () async {
      micLevel = 8000;
      incoming = 0;
      await connect();
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(state.call!.warn, 'out');
      expect(backend.fallbacks, 0);
    });

    test('everything audible gives no warning', () async {
      micLevel = 8000;
      incoming = 8000;
      await connect();
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(state.call!.warn, '');
    });

    test('muting suppresses the microphone warning', () async {
      micLevel = 0;
      incoming = 8000;
      await connect();
      calls.setMuted(true);
      expect(backend.mutes, [true]);
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(state.call!.warn, isNot('mic'));
      expect(state.call!.muted, isTrue);
    });

    test('no sound from the peer raises callWarn_none', () async {
      micLevel = 8000;
      incoming = -1;
      await calls.start('peer');
      final offer = signals.firstWhere((s) => s['k'] == 'offer');
      await calls.onSignal('peer', {'t': 'call', 'k': 'accept', 'id': offer['id']});
      pump = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => backend.emit(constant(micLevel)),
      );
      running = true;
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      expect(state.call!.warn, 'none');
    });

    test('a failing microphone ends the call with reason mic', () async {
      backend.failStart = true;
      await calls.start('peer');
      final offer = signals.firstWhere((s) => s['k'] == 'offer');
      await calls.onSignal('peer', {'t': 'call', 'k': 'accept', 'id': offer['id']});
      expect(state.call!.status, 'ended');
      expect(state.call!.reason, 'mic');
      expect(signals.last['k'], 'end');
    });
  });
}
