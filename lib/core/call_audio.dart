import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

const callRate = 48000;
const callFrame = 960;
const callFrameBytes = callFrame * 2;
const callBatch = 3;
const callBitrate = 16000;
const callJitter = 0.1;
const callMaxAhead = 0.4;

const _opusApplicationAudio = 2049;
const _opusSetBitrate = 4002;

abstract interface class CallAudioBackend {
  Stream<Uint8List> get pcm;
  Future<void> start({required bool raw});
  Future<void> play(Uint8List pcm);
  Future<void> setMuted(bool on);
  Future<void> fallback();
  Future<void> stop();
}

abstract interface class OpusEnc {
  Uint8List encode(Int16List pcm);
  void destroy();
}

abstract interface class OpusDec {
  Int16List decode(Uint8List frame);
  void destroy();
}

class OpusCodecs {
  const OpusCodecs(this.encoder, this.decoder);

  final OpusEnc Function() encoder;
  final OpusDec Function() decoder;
}

abstract interface class CallAudio {
  Future<void> start(void Function(List<Uint8List> opusFrames) onFrames);
  void play(List<Uint8List> opusFrames);
  Future<void> fallback();
  Map<String, Object?> stats();
  void setMuted(bool muted);
  void stop();
}

typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _MallocD = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
typedef _CreateC =
    Pointer<Void> Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _CreateD = Pointer<Void> Function(int, int, int, Pointer<Int32>);
typedef _CtlC =
    Int32 Function(Pointer<Void>, Int32, VarArgs<(Int32,)>);
typedef _CtlD = int Function(Pointer<Void>, int, int);
typedef _EncodeC =
    Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>, Int32);
typedef _EncodeD =
    int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);

class _NativeEnc implements OpusEnc {
  _NativeEnc(DynamicLibrary lib) {
    final libc = DynamicLibrary.process();
    final malloc = libc.lookupFunction<_MallocC, _MallocD>('malloc');
    _free = libc.lookupFunction<_FreeC, _FreeD>('free');
    _encode = lib.lookupFunction<_EncodeC, _EncodeD>('opus_encode');
    _destroy = lib.lookupFunction<_DestroyC, _DestroyD>('opus_encoder_destroy');
    final ctl = lib.lookupFunction<_CtlC, _CtlD>('opus_encoder_ctl');
    final create = lib.lookupFunction<_CreateC, _CreateD>(
      'opus_encoder_create',
    );
    final err = malloc(4).cast<Int32>();
    final enc = create(callRate, 1, _opusApplicationAudio, err);
    final code = err.value;
    _free(err.cast());
    if (code != 0 || enc.address == 0) throw StateError('opus_create_$code');
    _enc = enc;
    ctl(_enc, _opusSetBitrate, callBitrate);
    _in = malloc(callFrameBytes).cast<Int16>();
    _out = malloc(_maxPacket).cast<Uint8>();
  }

  static const _maxPacket = 1275;

  late final Pointer<Void> _enc;
  late final Pointer<Int16> _in;
  late final Pointer<Uint8> _out;
  late final _FreeD _free;
  late final _EncodeD _encode;
  late final _DestroyD _destroy;
  bool _dead = false;

  @override
  Uint8List encode(Int16List pcm) {
    if (_dead) throw StateError('opus_destroyed');
    _in.asTypedList(callFrame).setAll(0, pcm);
    final n = _encode(_enc, _in, callFrame, _out, _maxPacket);
    if (n < 0) throw StateError('opus_encode_$n');
    return Uint8List.fromList(_out.asTypedList(n));
  }

  @override
  void destroy() {
    if (_dead) return;
    _dead = true;
    _destroy(_enc);
    _free(_in.cast());
    _free(_out.cast());
  }
}

class _NativeDec implements OpusDec {
  _NativeDec() : _d = SimpleOpusDecoder(sampleRate: callRate, channels: 1);

  final SimpleOpusDecoder _d;

  @override
  Int16List decode(Uint8List frame) => _d.decode(input: frame);

  @override
  void destroy() {
    if (!_d.destroyed) _d.destroy();
  }
}

OpusCodecs? _loaded;
bool _opusInited = false;

OpusCodecs? opusCodecsFor(DynamicLibrary lib) {
  try {
    if (!_opusInited) {
      initOpus(lib as dynamic);
      _opusInited = true;
    }
    final probe = _NativeEnc(lib);
    probe.destroy();
    return OpusCodecs(() => _NativeEnc(lib), _NativeDec.new);
  } catch (_) {
    return null;
  }
}

Future<bool> prepareAudio([DynamicLibrary? lib]) async {
  if (_loaded != null) return true;
  try {
    final l = lib ?? (await opus_flutter.load() as DynamicLibrary);
    _loaded = opusCodecsFor(l);
  } catch (_) {
    _loaded = null;
  }
  return _loaded != null;
}

bool audioSupported() => _loaded != null && !Platform.isLinux;

class MethodChannelCallAudio implements CallAudioBackend {
  MethodChannelCallAudio({MethodChannel? methods, EventChannel? events})
    : _m = methods ?? const MethodChannel('ripplo/audio'),
      _e = events ?? const EventChannel('ripplo/audio/pcm');

  final MethodChannel _m;
  final EventChannel _e;

  @override
  Stream<Uint8List> get pcm =>
      _e.receiveBroadcastStream().where((e) => e is Uint8List).cast();

  @override
  Future<void> start({required bool raw}) =>
      _m.invokeMethod<void>('audioStart', {'raw': raw});

  @override
  Future<void> play(Uint8List pcm) =>
      _m.invokeMethod<void>('audioPlay', {'pcm': pcm});

  @override
  Future<void> setMuted(bool on) =>
      _m.invokeMethod<void>('audioMute', {'on': on});

  @override
  Future<void> fallback() => _m.invokeMethod<void>('audioFallback');

  @override
  Future<void> stop() => _m.invokeMethod<void>('audioStop');
}

double _peak(Int16List s) {
  var top = 0;
  for (final v in s) {
    final a = v < 0 ? -v : v;
    if (a > top) top = a;
  }
  return top / 32768;
}

class OpusCallAudio implements CallAudio {
  OpusCallAudio(
    this._backend, {
    OpusCodecs? codecs,
    int Function()? clockMs,
  }) : _codecs = codecs ?? _loadedOrThrow(),
       _clockMs = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static OpusCodecs _loadedOrThrow() {
    final c = _loaded;
    if (c == null) throw StateError('unsupported');
    return c;
  }

  final CallAudioBackend _backend;
  final OpusCodecs _codecs;
  final int Function() _clockMs;

  OpusEnc? _enc;
  OpusDec? _dec;
  StreamSubscription<Uint8List>? _sub;
  void Function(List<Uint8List>)? _onFrames;
  bool _stopped = false;
  bool _started = false;
  bool _muted = false;
  double _nextTime = 0;
  final List<Uint8List> _pending = [];
  int _sent = 0;
  int _recv = 0;
  int _played = 0;
  int _errors = 0;
  int _frames = 0;
  double _micPeak = 0;
  double _outPeak = 0;

  @override
  Future<void> start(void Function(List<Uint8List> opusFrames) onFrames) async {
    _onFrames = onFrames;
    _makeEncoder();
    _makeDecoder();
    _sub = _backend.pcm.listen(_capture, onError: (Object _) => _errors++);
    try {
      await _backend.start(raw: false);
    } catch (_) {
      await _sub?.cancel();
      _sub = null;
      _destroyCodecs();
      rethrow;
    }
    _started = true;
  }

  void _makeEncoder() {
    try {
      _enc?.destroy();
    } catch (_) {}
    _enc = _codecs.encoder();
  }

  void _makeDecoder() {
    try {
      _dec?.destroy();
    } catch (_) {}
    _dec = _codecs.decoder();
  }

  void _destroyCodecs() {
    try {
      _enc?.destroy();
    } catch (_) {}
    try {
      _dec?.destroy();
    } catch (_) {}
    _enc = null;
    _dec = null;
  }

  void _capture(Uint8List bytes) {
    if (_stopped) return;
    _frames++;
    if (bytes.length != callFrameBytes) {
      _errors++;
      return;
    }
    final pcm = Uint8List.fromList(bytes).buffer.asInt16List();
    if (_muted) pcm.fillRange(0, pcm.length, 0);
    _micPeak = math.max(_micPeak, _peak(pcm));
    try {
      final out = _enc!.encode(pcm);
      _pending.add(out);
      if (_pending.length >= callBatch) {
        _sent += _pending.length;
        final batch = List<Uint8List>.of(_pending);
        _pending.clear();
        _onFrames?.call(batch);
      }
    } catch (_) {
      _errors++;
      try {
        _makeEncoder();
      } catch (_) {}
    }
  }

  @override
  void play(List<Uint8List> opusFrames) {
    if (!_started || _stopped) return;
    _recv += opusFrames.length;
    for (final f in opusFrames) {
      Int16List pcm;
      try {
        pcm = _dec!.decode(f);
      } catch (_) {
        _errors++;
        try {
          _makeDecoder();
        } catch (_) {}
        continue;
      }
      _playPcm(pcm);
    }
  }

  void _playPcm(Int16List pcm) {
    _outPeak = math.max(_outPeak, _peak(pcm));
    if (_stopped) return;
    final now = _clockMs() / 1000;
    if (_nextTime < now + 0.02) _nextTime = now + callJitter;
    if (_nextTime - now > callMaxAhead) return;
    _nextTime += pcm.length / callRate;
    _played++;
    final bytes = Uint8List.fromList(Uint8List.sublistView(pcm));
    _backend.play(bytes).catchError((Object _) => _errors++);
  }

  @override
  Future<void> fallback() async {
    if (_stopped || !_started) return;
    await _backend.fallback();
  }

  @override
  Map<String, Object?> stats() {
    final out = <String, Object?>{
      'sent': _sent,
      'recv': _recv,
      'played': _played,
      'errors': _errors,
      'frames': _frames,
      'mic': _micPeak,
      'out': _outPeak,
      'ctx': _started && !_stopped ? 'running' : 'none',
      'track': !_started ? 'none' : (_stopped ? 'ended' : 'live'),
    };
    _micPeak = 0;
    _outPeak = 0;
    return out;
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
    _backend.setMuted(muted).catchError((Object _) {});
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _sub?.cancel();
    _sub = null;
    _destroyCodecs();
    _backend.stop().catchError((Object _) {});
  }
}

Future<CallAudio> createAudio([CallAudioBackend? backend]) async {
  if (!audioSupported()) throw StateError('unsupported');
  return OpusCallAudio(backend ?? MethodChannelCallAudio());
}
