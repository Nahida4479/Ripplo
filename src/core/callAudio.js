const RATE = 48000
const FRAME = 960
const BATCH = 3
const BITRATE = 16000
const JITTER = 0.1
const MAX_AHEAD = 0.4

export const audioSupported = () =>
  !!(globalThis.AudioEncoder && globalThis.AudioDecoder && globalThis.AudioData && globalThis.EncodedAudioChunk && globalThis.AudioWorkletNode)

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

  function playData(data) {
    const pcm = new Float32Array(data.numberOfFrames)
    data.copyTo(pcm, { planeIndex: 0, format: 'f32-planar' })
    data.close()
    if (stopped || !ctx) return
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
      encoder = new AudioEncoder({
        output: (chunk) => {
          const bytes = new Uint8Array(chunk.byteLength)
          chunk.copyTo(bytes)
          pending.push(bytes)
          if (pending.length >= BATCH) onFrames(pending.splice(0))
        },
        error: () => {},
      })
      encoder.configure({ codec: 'opus', sampleRate: RATE, numberOfChannels: 1, bitrate: BITRATE })
      decoder = new AudioDecoder({ output: playData, error: () => {} })
      decoder.configure({ codec: 'opus', sampleRate: RATE, numberOfChannels: 1 })
      node.port.onmessage = (e) => {
        if (stopped) return
        const data = new AudioData({ format: 'f32-planar', sampleRate: RATE, numberOfFrames: FRAME, numberOfChannels: 1, timestamp: tsOut, data: e.data })
        tsOut += 20000
        encoder.encode(data)
        data.close()
      }
      started = true
    },

    play(frames) {
      if (!started || stopped) return
      for (const f of frames) {
        decoder.decode(new EncodedAudioChunk({ type: 'key', timestamp: tsIn, data: f }))
        tsIn += 20000
      }
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
