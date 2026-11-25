import AVFoundation
import AudioToolbox

final class Ringer {
    static let shared = Ringer()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var timer: Timer?

    func start() {
        guard engine == nil, timer == nil else { return }
        startTone()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    func stop() {
        guard engine != nil || timer != nil else { return }
        timer?.invalidate()
        timer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        if !CallAudio.shared.isRunning {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startTone() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [])
        try? session.setActive(true)
        let rate = 44100.0
        let total = Int(rate * 2.5)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)),
              let samples = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(total)
        for i in 0..<total {
            let t = Double(i) / rate
            if t < 0.4 {
                samples[i] = Float(sin(2 * Double.pi * 440 * t) * 0.3)
            } else if t < 0.8 {
                samples[i] = Float(sin(2 * Double.pi * 480 * (t - 0.4)) * 0.3)
            } else {
                samples[i] = 0
            }
        }
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: fmt)
        do {
            try e.start()
        } catch {
            return
        }
        p.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        p.play()
        engine = e
        player = p
    }
}
