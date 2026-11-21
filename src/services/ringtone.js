import { mesh } from '../mesh/bridge.js'

let ctx = null
let timer = null
let native = false

function beep(freq, at, length) {
  const osc = ctx.createOscillator()
  const gain = ctx.createGain()
  osc.frequency.value = freq
  gain.gain.setValueAtTime(0.0001, at)
  gain.gain.exponentialRampToValueAtTime(0.25, at + 0.03)
  gain.gain.exponentialRampToValueAtTime(0.0001, at + length)
  osc.connect(gain).connect(ctx.destination)
  osc.start(at)
  osc.stop(at + length + 0.05)
}

function cycle() {
  if (!ctx) return
  const now = ctx.currentTime
  beep(440, now, 0.4)
  beep(480, now + 0.5, 0.4)
  if (navigator.vibrate) navigator.vibrate([400, 150, 400])
}

export function startRing() {
  stopRing()
  if (mesh.isNative) {
    native = true
    mesh.startRing().catch(webRing)
    return
  }
  webRing()
}

function webRing() {
  try {
    ctx = new AudioContext()
    ctx.resume().catch(() => {})
    cycle()
    timer = setInterval(cycle, 2500)
  } catch {
    ctx = null
  }
}

export function stopRing() {
  if (native) {
    native = false
    mesh.stopRing()
  }
  clearInterval(timer)
  timer = null
  if (navigator.vibrate) navigator.vibrate(0)
  ctx?.close().catch(() => {})
  ctx = null
}
