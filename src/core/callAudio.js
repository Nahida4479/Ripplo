const RATE = 48000
const FRAME = 960
const BATCH = 3
const BITRATE = 16000
const JITTER = 0.1
const MAX_AHEAD = 0.4

export const audioSupported = () =>
  !!(globalThis.AudioEncoder && globalThis.AudioDecoder && globalThis.AudioData && globalThis.EncodedAudioChunk && globalThis.AudioWorkletNode)

function toFloat(data) {
  const n = data.numberOfFrames
  if (data.format && data.format.startsWith('s16')) {
    const ints = new Int16Array(n)
    data.copyTo(ints, { planeIndex: 0 })
    const out = new Float32Array(n)
    for (let i = 0; i < n; i++) out[i] = ints[i] / 32768
    return out
  }
  const out = new Float32Array(n)
  data.copyTo(out, { planeIndex: 0 })
  return out
}

export async function createAudio() {
  if (!audioSupported()) throw new Error('unsupported')
  let ctx = null
  let stream = null
  let node = null
  let encoder = null
  let decoder = null
  let stopped = false
  let started = false
  let nextTime = 0
  let tsOut = 0
  let tsIn = 0
  const pending = []
  const counts = { sent: 0, recv: 0, played: 0, errors: 0 }
  const peaks = { mic: 0, out: 0 }

  function makeEncoder(onFrames) {
    encoder = new AudioEncoder({
      output: (chunk) => {
        const bytes = new Uint8Array(chunk.byteLength)
        chunk.copyTo(bytes)
        pending.push(bytes)
        if (pending.length >= BATCH) {
          counts.sent += pending.length
          onFrames(pending.splice(0))
        }
      },
      error: () => {
        counts.errors++
        if (!stopped) makeEncoder(onFrames)
      },
    })
    encoder.configure({ codec: 'opus', sampleRate: RATE, numberOfChannels: 1, bitrate: BITRATE })
  }

  function makeDecoder() {
    decoder = new AudioDecoder({
      output: playData,
      error: () => {
        counts.errors++
        if (!stopped) makeDecoder()
      },
    })
    decoder.configure({ codec: 'opus', sampleRate: RATE, numberOfChannels: 1 })
  }

  function playData(data) {
    let pcm
    try {
      pcm = toFloat(data)
    } catch {
      counts.errors++
      return
    } finally {
      data.close()
    }
    let top = 0
    for (let i = 0; i < pcm.length; i++) top = Math.max(top, Math.abs(pcm[i]))
    peaks.out = Math.max(peaks.out, top)
    if (stopped || !ctx) return
    if (ctx.state === 'suspended') ctx.resume().catch(() => {})
    const now = ctx.currentTime
    if (nextTime < now + 0.02) nextTime = now + JITTER
    if (nextTime - now > MAX_AHEAD) return
    const buffer = ctx.createBuffer(1, pcm.length, RATE)
    buffer.copyToChannel(pcm, 0)
    const src = ctx.createBufferSource()
    src.buffer = buffer
    src.connect(ctx.destination)
    src.start(nextTime)
    nextTime += pcm.length / RATE
    counts.played++
  }

  return {
    async start(onFrames) {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
      })
      ctx = new AudioContext({ sampleRate: RATE, latencyHint: 'interactive' })
      await ctx.resume()
      await ctx.audioWorklet.addModule('/call-worklet.js')
      node = new AudioWorkletNode(ctx, 'ripplo-capture', { processorOptions: { frame: FRAME } })
      const silent = ctx.createGain()
      silent.gain.value = 0
      ctx.createMediaStreamSource(stream).connect(node)
      node.connect(silent).connect(ctx.destination)
      makeEncoder(onFrames)
      makeDecoder()
      node.port.onmessage = (e) => {
        if (stopped) return
        let top = 0
        for (let i = 0; i < e.data.length; i++) top = Math.max(top, Math.abs(e.data[i]))
        peaks.mic = Math.max(peaks.mic, top)
        try {
          if (encoder.state === 'closed') makeEncoder(onFrames)
          const data = new AudioData({ format: 'f32-planar', sampleRate: RATE, numberOfFrames: FRAME, numberOfChannels: 1, timestamp: tsOut, data: e.data })
          tsOut += 20000
          encoder.encode(data)
          data.close()
        } catch {
          counts.errors++
        }
      }
      started = true
    },

    play(frames) {
      if (!started || stopped) return
      counts.recv += frames.length
      for (const f of frames) {
        try {
          if (decoder.state === 'closed') makeDecoder()
          decoder.decode(new EncodedAudioChunk({ type: 'key', timestamp: tsIn, data: f }))
        } catch {
          counts.errors++
          makeDecoder()
        }
        tsIn += 20000
      }
    },

    stats() {
      const out = { ...counts, mic: peaks.mic, out: peaks.out }
      peaks.mic = 0
      peaks.out = 0
      return out
    },

    setMuted(muted) {
      if (stream) for (const t of stream.getAudioTracks()) t.enabled = !muted
    },

    stop() {
      stopped = true
      if (node) node.port.onmessage = null
      if (stream) for (const t of stream.getTracks()) t.stop()
      try { encoder?.close() } catch {}
      try { decoder?.close() } catch {}
      ctx?.close().catch(() => {})
      ctx = null
    },
  }
}
