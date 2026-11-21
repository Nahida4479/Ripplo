import { Capacitor, registerPlugin } from '@capacitor/core'
import { TYPE, encodePacket } from './packet.js'
import { Router } from './router.js'
import { createDevSignal } from './devSignal.js'

const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s) }
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
const unsupported = () => Promise.reject(Object.assign(new Error('unsupported'), { code: 'unsupported' }))
const GRANTED = { bluetooth: 'granted', wifi: 'granted', notifications: 'granted', microphone: 'granted' }

function nativeMesh() {
  const P = registerPlugin('RipploMesh')
  const inbound = (e) => ({ packet: unb64(e.packet), from: e.from })
  return {
    isNative: true,
    devCrypto: false,
    async signalInit() { const r = await P.signalInit(); return { bundle: unb64(r.bundle), ik: unb64(r.ik) } },
    signalAddContact: async (bundle) => (await P.signalAddContact({ bundle: b64(bundle) })).tag,
    signalSeal: async (tag, plaintext) => unb64((await P.signalSeal({ tag, plaintext: b64(plaintext) })).payload),
    async signalOpen(payload) { const r = await P.signalOpen({ payload: b64(payload) }); return { tag: r.tag, ik: unb64(r.ik), plaintext: unb64(r.plaintext) } },
    signalProof: async (ik, n, challengerTag, proverTag) => unb64((await P.signalProof({ ik: b64(ik), n: b64(n), challengerTag: b64(challengerTag), proverTag: b64(proverTag) })).mac),
    signalSafetyNumber: async (ik) => (await P.signalSafetyNumber({ ik: b64(ik) })).digits,
    signalForget: (tag) => P.signalForget({ tag }),
    start: (selfTag) => P.start({ selfTag: b64(selfTag) }),
    send: (packet) => P.send({ packet: b64(packet) }),
    sendApp: (node, payload) => P.sendApp({ node, payload: b64(payload) }),
    getNeighbors: async () => (await P.getNeighbors()).neighbors,
    drainInbox: async () => (await P.drainInbox()).packets.map((e) => (e.opened ? { opened: e.opened } : inbound(e))),
    takeOpen: async () => { try { return (await P.takeOpen()).open || null } catch { return null } },
    getDbKey: async () => ({ key: unb64((await P.getDbKey()).key), insecure: false }),
    selfHash: async () => (await P.selfHash()).sha256,
    installUpdate: (url, sha256, prompt) => P.installUpdate({ url, sha256, prompt }),
    requestBatteryExemption: () => P.requestBatteryExemption(),
    setAutoUpdate: (enabled) => P.setAutoUpdate({ enabled }),
    requestFullScreen: () => P.requestFullScreen(),
    startRing: () => P.startRing(),
    stopRing: () => P.stopRing().catch(() => {}),
    takeShare: async () => { try { return (await P.takeShare()).share || null } catch { return null } },
    checkPermissions: () => P.checkPermissions(),
    requestPermissions: () => P.requestPermissions(),
    dbPut: ({ store, key, idx, value }) => P.dbPut({ store, key, idx, value: b64(value) }),
    dbPutMany: ({ rows }) => P.dbPutMany({ rows: rows.map((r) => ({ ...r, value: b64(r.value) })) }),
    async dbGet(a) { const r = await P.dbGet(a); return r.value == null ? null : unb64(r.value) },
    dbDel: (a) => P.dbDel(a),
    async dbKeys(a) { return (await P.dbKeys(a)).keys },
    async dbAll(a) { return (await P.dbAll(a)).rows.map((r) => ({ key: r.key, value: unb64(r.value) })) },
    async dbByIdx(a) { return (await P.dbByIdx(a)).rows.map((r) => ({ key: r.key, value: unb64(r.value) })) },
    async dbCount() { return (await P.dbCount()).count },
    authAvailable: () => P.authAvailable(),
    authenticate: (reason) => P.authenticate({ reason }),
    setSecure: (on) => P.setSecure({ on }),
    backupStatus: () => P.backupStatus(),
    backupEnable: () => P.backupEnable(),
    backupShowCode: () => P.backupShowCode(),
    backupDisable: () => P.backupDisable(),
    backupChooseFolder: () => P.backupChooseFolder(),
    backupCreate: (a) => P.backupCreate(a),
    backupRestore: (a) => P.backupRestore(a),
    on(event, cb) {
      const h = P.addListener(event, (e) => cb(event === 'packet' ? inbound(e) : e))
      return () => h.then((x) => x.remove())
    },
  }
}

function devStore() {
  const key = `ripplo-dev-bundle-${new URLSearchParams(location.search).get('profile') || 'default'}`
  return {
    get: () => { try { const v = localStorage.getItem(key); return v && unb64(v) } catch { return null } },
    set: (b) => { try { localStorage.setItem(key, b64(b)) } catch {} },
  }
}

function webMesh() {
  const solo = new URLSearchParams(location.search).has('solo')
  const nodeTag = hex(crypto.getRandomValues(new Uint8Array(16)))
  const ch = new BroadcastChannel('ripplo-mesh')
  const listeners = {}
  const emit = (ev, d) => (listeners[ev] || []).forEach((cb) => cb(d))
  const peers = new Map()
  let router

  const hello = () => ch.postMessage({ t: 'hello', node: nodeTag })
  const drop = (node) => { peers.delete(node); router.linkDown(node); emit('neighbor', { node, up: false, medium: 'lan', kbps: 20000 }) }
  const see = (node) => {
    if (!peers.has(node)) {
      router.linkUp(node)
      emit('neighbor', { node, up: true, medium: 'lan', kbps: 20000 })
      hello()
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
    devCrypto: true,
    ...createDevSignal(devStore()),
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
    takeOpen: async () => null,
    async getDbKey() {
      let k = localStorage.getItem('ripplo-dbkey')
      if (!k) localStorage.setItem('ripplo-dbkey', (k = b64(crypto.getRandomValues(new Uint8Array(32)))))
      return { key: unb64(k), insecure: true }
    },
    selfHash: async () => null,
    authAvailable: async () => ({ biometric: false, deviceCredential: false }),
    authenticate: async () => ({ ok: true }),
    setSecure: async () => ({}),
    backupStatus: async () => ({ enabled: false, lastAt: 0, folder: null }),
    backupEnable: unsupported,
    backupShowCode: unsupported,
    backupDisable: unsupported,
    backupChooseFolder: unsupported,
    backupCreate: unsupported,
    backupRestore: unsupported,
    installUpdate: async () => { throw new Error('unsupported') },
    requestBatteryExemption: async () => {},
    setAutoUpdate: async () => {},
    requestFullScreen: async () => {},
    startRing: () => Promise.reject(new Error('unsupported')),
    stopRing: async () => {},
    takeShare: async () => null,
    checkPermissions: async () => GRANTED,
    requestPermissions: async () => GRANTED,
    on(event, cb) {
      (listeners[event] ||= []).push(cb)
      return () => { listeners[event] = listeners[event].filter((x) => x !== cb) }
    },
  }
}

export const mesh = Capacitor.isNativePlatform() ? nativeMesh() : webMesh()
