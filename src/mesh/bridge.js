import { Capacitor, registerPlugin } from '@capacitor/core'
import { TYPE, encodePacket } from './packet.js'
import { Router } from './router.js'

const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s) }
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
const GRANTED = { bluetooth: 'granted', wifi: 'granted', notifications: 'granted' }

function nativeMesh() {
  const P = registerPlugin('RipploMesh')
  const inbound = (e) => ({ packet: unb64(e.packet), from: e.from })
  return {
    isNative: true,
    start: (selfTag) => P.start({ selfTag: b64(selfTag) }),
    send: (packet) => P.send({ packet: b64(packet) }),
    sendApp: (node, payload) => P.sendApp({ node, payload: b64(payload) }),
    getNeighbors: async () => (await P.getNeighbors()).neighbors,
    drainInbox: async () => (await P.drainInbox()).packets.map(inbound),
    getDbKey: async () => ({ key: unb64((await P.getDbKey()).key), insecure: false }),
    selfHash: async () => (await P.selfHash()).sha256,
    installUpdate: (url, sha256) => P.installUpdate({ url, sha256 }),
    requestBatteryExemption: () => P.requestBatteryExemption(),
    checkPermissions: () => P.checkPermissions(),
    requestPermissions: () => P.requestPermissions(),
    on(event, cb) {
      const h = P.addListener(event, (e) => cb(event === 'packet' ? inbound(e) : e))
      return () => h.then((x) => x.remove())
    },
  }
}

// Dev fallback: every browser tab is a node; tabs see each other over BroadcastChannel.
function webMesh() {
  const solo = new URLSearchParams(location.search).has('solo')
  const nodeTag = hex(crypto.getRandomValues(new Uint8Array(16)))
  const ch = new BroadcastChannel('ripplo-mesh')
  const listeners = {}
  const emit = (ev, d) => (listeners[ev] || []).forEach((cb) => cb(d))
  const peers = new Map() // node -> last seen ms
  let router

  const hello = () => ch.postMessage({ t: 'hello', node: nodeTag })
  const drop = (node) => { peers.delete(node); router.linkDown(node); emit('neighbor', { node, up: false, medium: 'lan', kbps: 20000 }) }
  const see = (node) => {
    if (!peers.has(node)) {
      router.linkUp(node)
      emit('neighbor', { node, up: true, medium: 'lan', kbps: 20000 })
      hello() // let the newcomer learn about us immediately
    }
    peers.set(node, Date.now())
  }

  ch.onmessage = ({ data: m }) => {
    if (solo || !router || m.node === nodeTag) return
    if (m.t === 'hello') see(m.node)
    else if (m.t === 'bye') peers.has(m.node) && drop(m.node)
    else if (m.t === 'pkt' && m.to === nodeTag) { see(m.from); router.onPacket(m.bytes, m.from) }
  }
  addEventListener('pagehide', () => ch.postMessage({ t: 'bye', node: nodeTag }))

  return {
    isNative: false,
    async start(selfTag) {
      if (router) return { nodeTag }
      router = new Router({
        selfTag,
        sendTo: (to, bytes) => ch.postMessage({ t: 'pkt', from: nodeTag, to, bytes }),
        deliver: (packet, from) => emit('packet', { packet, from }),
      })
      hello()
      setInterval(() => {
        hello()
        for (const [n, t] of peers) if (Date.now() - t > 5000) drop(n)
      }, 2000)
      return { nodeTag }
    },
    async send(packet) { router.onPacket(packet, 'self'); return { neighbors: router.neighbors().length } },
    async sendApp(node, payload) {
      ch.postMessage({ t: 'pkt', from: nodeTag, to: node, bytes: encodePacket({ type: TYPE.APP, payload }) })
    },
    async getNeighbors() {
      return router.neighbors().map((node) => ({ node, medium: 'lan', kbps: 20000, rttMs: 1, links: [{ medium: 'lan', kbps: 20000 }] }))
    },
    drainInbox: async () => [],
    async getDbKey() {
      let k = localStorage.getItem('ripplo-dbkey')
      if (!k) localStorage.setItem('ripplo-dbkey', (k = b64(crypto.getRandomValues(new Uint8Array(32)))))
      return { key: unb64(k), insecure: true }
    },
    selfHash: async () => null,
    installUpdate: async () => { throw new Error('unsupported') },
    requestBatteryExemption: async () => {},
    checkPermissions: async () => GRANTED,
    requestPermissions: async () => GRANTED,
    on(event, cb) {
      (listeners[event] ||= []).push(cb)
      return () => { listeners[event] = listeners[event].filter((x) => x !== cb) }
    },
  }
}

export const mesh = Capacitor.isNativePlatform() ? nativeMesh() : webMesh()
