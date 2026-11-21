import { b64, unb64, random } from '../lib/bytes.js'
import { importCallKey, sealFrame, openFrame, packFrames, unpackFrames, createReplay } from '../crypto/callFrame.js'
import { RipploError } from '../crypto/identity.js'

const DEFAULT_TIMING = { ring: 45000, silence: 6000, first: 30000, hold: 2500, stale: 120000 }
const ID_LEN = 8
const KEY_LEN = 32

const decode = (s, len) => {
  try {
    const b = unb64(String(s))
    return b.length === len ? b : null
  } catch {
    return null
  }
}

export function createCalls({ state, signal, sendMedia, hasNeighbor, supported, newAudio, notify, log, timing = {} }) {
  const T = { ...DEFAULT_TIMING, ...timing }
  let cur = null

  const open = (peer, role, id) => ({
    peer, role, id, idB64: b64(id), key: null, audio: null, seq: 0, live: false, done: false, heard: false,
    replay: createReplay(), lastRx: 0, ringTimer: null, watch: null,
  })

  function finish(c, reason, tell) {
    if (c.done) return
    c.done = true
    clearTimeout(c.ringTimer)
    clearInterval(c.watch)
    if (tell) signal(c.peer, { t: 'call', k: tell, id: c.idB64 })
    if (c.audio) c.audio.stop()
    const startedAt = state.call?.startedAt || 0
    log(c.peer, reason, startedAt ? Date.now() - startedAt : 0)
    state.call = { ...state.call, status: 'ended', reason }
    if (cur === c) cur = null
    setTimeout(() => {
      if (state.call?.status === 'ended' && state.call.peer === c.peer) state.call = null
    }, T.hold)
  }

  async function begin(c) {
    clearTimeout(c.ringTimer)
    state.call = { ...state.call, status: 'connecting' }
    try {
      c.audio = await newAudio()
      if (c.done) {
        c.audio.stop()
        return
      }
      await c.audio.start(async (frames) => {
        if (cur !== c || c.done || !c.live) return
        const packet = await sealFrame(c.key, c.id, c.role, c.seq++, packFrames(frames))
        sendMedia(c.peer, packet)
      })
    } catch {
      try { c.audio?.stop() } catch {}
      finish(c, 'mic', 'end')
      return
    }
    if (c.done) {
      c.audio.stop()
      return
    }
    c.live = true
    c.lastRx = Date.now()
    state.call = { ...state.call, status: 'active', startedAt: Date.now() }
    c.watch = setInterval(() => {
      if (c.audio.stats) state.call = { ...state.call, stats: c.audio.stats() }
      if (Date.now() - c.lastRx > (c.heard ? T.silence : T.first) || !hasNeighbor(c.peer)) finish(c, 'lost', 'end')
    }, 1000)
  }

  async function start(peer) {
    if (cur) throw new RipploError('call_busy')
    if (!supported()) throw new RipploError('call_unsupported')
    if (!hasNeighbor(peer)) throw new RipploError('call_no_link')
    const raw = random(KEY_LEN)
    const c = open(peer, 0, random(ID_LEN))
    cur = c
    state.call = { peer, dir: 'out', status: 'ringing', muted: false, startedAt: 0 }
    c.key = await importCallKey(raw)
    if (c.done) return
    c.ringTimer = setTimeout(() => finish(c, 'noanswer', 'end'), T.ring)
    signal(peer, { t: 'call', k: 'offer', id: c.idB64, key: b64(raw), ts: Date.now() }).then((r) => {
      if (!r.ok && !c.done && state.call?.status === 'ringing') finish(c, 'unreachable', null)
    })
  }

  async function onOffer(f, msg) {
    const id = decode(msg.id, ID_LEN)
    const raw = decode(msg.key, KEY_LEN)
    if (!id || !raw) return
    if (Number.isFinite(msg.ts) && Date.now() - msg.ts > T.stale) return
    if (cur && msg.id === cur.idB64) return
    if (cur || !supported()) {
      signal(f, { t: 'call', k: 'decline', id: msg.id, r: 'busy' })
      return
    }
    const c = open(f, 1, id)
    cur = c
    state.call = { peer: f, dir: 'in', status: 'ringing', muted: false, startedAt: 0 }
    c.key = await importCallKey(raw)
    notify(f)
    c.ringTimer = setTimeout(() => finish(c, 'missed', null), T.ring)
  }

  async function onSignal(f, msg) {
    if (msg.k === 'offer') return onOffer(f, msg)
    const c = cur
    if (!c || c.peer !== f || msg.id !== c.idB64) return
    if (msg.k === 'accept' && c.role === 0 && state.call?.status === 'ringing') await begin(c)
    else if (msg.k === 'decline') finish(c, msg.r === 'busy' ? 'busy' : 'declined', null)
    else if (msg.k === 'end') finish(c, c.role === 1 && state.call?.status === 'ringing' ? 'missed' : 'ended', null)
  }

  async function accept() {
    const c = cur
    if (!c || c.role !== 1 || state.call?.status !== 'ringing') return
    clearTimeout(c.ringTimer)
    signal(c.peer, { t: 'call', k: 'accept', id: c.idB64 })
    await begin(c)
  }

  function hangup() {
    const c = cur
    if (!c) return
    const ringing = state.call?.status === 'ringing'
    if (c.role === 1 && ringing) finish(c, 'declined', 'decline')
    else finish(c, ringing ? 'cancelled' : 'ended', 'end')
  }

  async function onMedia(bytes) {
    const c = cur
    if (!c || !c.live) return
    let opened
    try {
      opened = await openFrame(c.key, c.id, 1 - c.role, bytes)
    } catch {
      return
    }
    if (cur !== c || !c.replay.accept(opened.seq)) return
    let frames
    try {
      frames = unpackFrames(opened.plain)
    } catch {
      return
    }
    c.lastRx = Date.now()
    c.heard = true
    c.audio.play(frames)
  }

  function setMuted(muted) {
    if (!cur) return
    if (cur.audio) cur.audio.setMuted(!!muted)
    state.call = { ...state.call, muted: !!muted }
  }

  return { start, accept, hangup, onSignal, onMedia, setMuted }
}
