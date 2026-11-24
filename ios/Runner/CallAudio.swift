import AVFoundation
import Flutter

private enum CallAudioError: Error {
    case noInput
}

final class CallAudio: NSObject, FlutterStreamHandler {
    static let shared = CallAudio()

    private static let rate = 48000.0
    private static let frame = 960
    private static let primeSamples = 4800
    private static let maxQueued = 19200

    private let q = DispatchQueue(label: "ripplo.callaudio")
    private let lock = NSLock()
    private var sink: FlutterEventSink?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var generation = 0
    private var playing = false
    private var queued = 0
    private var active = false
    private var muted = false
    private var inbuf = [Float]()
    private var acc = [Float]()
    private var pos = 0.0
    private var step = 1.0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let methods = FlutterMethodChannel(name: "ripplo/audio", binaryMessenger: messenger)
        methods.setMethodCallHandler { call, result in
            CallAudio.shared.handle(call, result)
        }
        FlutterEventChannel(name: "ripplo/audio/pcm", binaryMessenger: messenger).setStreamHandler(CallAudio.shared)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "audioStart":
            begin(raw: a["raw"] as? Bool ?? false, result)
        case "audioFallback":
            begin(raw: true, result)
        case "audioPlay":
            if let d = a["pcm"] as? FlutterStandardTypedData {
                let bytes = d.data
                q.async { self.play(bytes) }
            }
            result(nil)
        case "audioMute":
            lock.lock()
            muted = a["on"] as? Bool ?? false
            lock.unlock()
            result(nil)
        case "audioStop":
            q.async {
                self.teardown(deactivate: true)
                DispatchQueue.main.async { result(nil) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    private func begin(raw: Bool, _ result: @escaping FlutterResult) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            self.q.async {
                guard granted else {
                    self.reply(result, FlutterError(code: "audio_permission", message: "microphone denied", details: nil))
                    return
                }
                do {
                    try self.setup(raw: raw)
                    self.reply(result, nil)
                } catch {
                    self.teardown(deactivate: true)
                    self.reply(result, FlutterError(code: "audio_failed", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func setup(raw: Bool) throws {
        teardown(deactivate: false)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: raw ? .default : .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setPreferredSampleRate(CallAudio.rate)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        let e = AVAudioEngine()
        let input = e.inputNode
        if !raw { try input.setVoiceProcessingEnabled(true) }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let pf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CallAudio.rate, channels: 1, interleaved: false) else {
            throw CallAudioError.noInput
        }
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: pf)
        lock.lock()
        inbuf.removeAll()
        acc.removeAll()
        pos = 0
        step = inFormat.sampleRate / CallAudio.rate
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.capture(buf)
        }
        e.prepare()
        try e.start()
        generation += 1
        engine = e
        player = p
        playFormat = pf
        playing = false
        queued = 0
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            self?.q.async { self?.restart() }
        }
        lock.lock()
        active = true
        lock.unlock()
    }

    private func restart() {
        guard let e = engine, !e.isRunning else { return }
        try? e.start()
        if playing, e.isRunning { player?.play() }
    }

    private func teardown(deactivate: Bool) {
        generation += 1
        lock.lock()
        active = false
        inbuf.removeAll()
        acc.removeAll()
        pos = 0
        lock.unlock()
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        playFormat = nil
        playing = false
        queued = 0
        if deactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func capture(_ buf: AVAudioPCMBuffer) {
        guard let channels = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        var frames = [Data]()
        lock.lock()
        if active {
            inbuf.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: n))
            while pos + 1 < Double(inbuf.count) {
                let i = Int(pos)
                let f = Float(pos - Double(i))
                acc.append(inbuf[i] + (inbuf[i + 1] - inbuf[i]) * f)
                pos += step
            }
            let drop = min(Int(pos), inbuf.count)
            if drop > 0 {
                inbuf.removeFirst(drop)
                pos -= Double(drop)
            }
            while acc.count >= CallAudio.frame {
                var d = Data(count: CallAudio.frame * 2)
                let silent = muted
                d.withUnsafeMutableBytes { raw in
                    let out = raw.bindMemory(to: Int16.self)
                    for k in 0..<CallAudio.frame {
                        let x = acc[k]
                        let v: Float = (silent || !x.isFinite) ? 0 : max(-1, min(1, x))
                        out[k] = Int16(v * 32767).littleEndian
                    }
                }
                acc.removeFirst(CallAudio.frame)
                frames.append(d)
            }
        }
        lock.unlock()
        for d in frames {
            DispatchQueue.main.async { self.sink?(FlutterStandardTypedData(bytes: d)) }
        }
    }

    private func play(_ d: Data) {
        guard let e = engine, let p = player, let pf = playFormat else { return }
        let n = d.count / 2
        guard n > 0, queued + n <= CallAudio.maxQueued,
              let buf = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: AVAudioFrameCount(n)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let bytes = [UInt8](d)
        for i in 0..<n {
            let v = Int16(bitPattern: UInt16(bytes[2 * i]) | (UInt16(bytes[2 * i + 1]) << 8))
            out[i] = Float(v) / 32768
        }
        let gen = generation
        queued += n
        p.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
            self.q.async { self.played(n, gen) }
        }
        if !playing, queued >= CallAudio.primeSamples, e.isRunning {
            p.play()
            playing = true
        }
    }

    private func played(_ n: Int, _ gen: Int) {
        guard gen == generation else { return }
        queued = max(0, queued - n)
        if queued == 0, playing {
            playing = false
            player?.pause()
        }
    }
}
