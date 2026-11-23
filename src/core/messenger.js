import { sha256 } from '@noble/hashes/sha2.js'
import { TYPE, newId, encodePacket, decodePacket } from '../mesh/packet.js'
import { b64, b64url, unb64, hex, unhex, utf8, unutf8, concat, random, equal } from '../lib/bytes.js'
import { createVault } from '../crypto/vault.js'
import { openDb } from '../crypto/db.js'
import { RipploError, encodeCard, checkCard, encodeLink, parseLink, deriveIds, cleanName } from '../crypto/identity.js'
import { CHUNK, encryptFile, decryptFile, chunkCount, chunkPayload, parseChunk } from '../crypto/attachment.js'
import { isAvatar } from '../lib/avatar.js'
import { createCalls } from './calls.js'
import { FRAME_TAG } from '../crypto/callFrame.js'
import { createAudio, audioSupported } from './callAudio.js'
import { createState } from './state.js'
import { notify } from '../services/notifications.js'
import { t } from '../i18n.js'
import { diagLog } from './diag.js'

export const MAX_TEXT = 1000
export const MAX_FILE = 20 * 1024 * 1024

const MAX_PENDING = 100 * 1024 * 1024
const PENDING_TTL = 24 * 3600 * 1000
const MAX_CHUNKS = 700
const MAX_GROUP = 30
const MAX_WAVE = 64
const RE_TEXT = 120
const MAX_TOKENS = 30
const MAX_UNSENT = 1000
const MAX_USED = 200
const TOKEN_RE = /^[A-Za-z0-9_-]{11}$/
const MAX_SCAN = 20
const MAX_SEARCH = 50
const RINGS = [1, 3, 8, 255]
const MAX_HELLOS = 64
const WINDOW = 4
const ID_RE = /^[0-9A-HJKMNP-TV-Z]{16}$/
const WIRE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/
const KINDS = ['image', 'video', 'voice']
const RESET_GAP = 10 * 60 * 1000
const TYPING_TAG = 2
const DEFAULT_TIMING = { ack: 60000, chunkAck: 20000, tries: 4, retry: 2000, resend: 15000, typing: 3000, typingTtl: 5000, discover: 30000, quiet: 10000, ring: 8000, quietRing: 3000, helloRetry: 3000, verify: 60000, proof: 5000, poll: 500 }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const latin1 = (bytes) => Array.from(bytes, (b) => String.fromCharCode(b)).join('')
const pktId = (pkt) => hex(pkt.subarray(4, 20))
const safeMime = (m) => {
  const base = String(m || '').split(';')[0].trim().toLowerCase()
  return /^(image|video|audio)\/[a-z0-9.+-]{1,40}$/.test(base) ? base : 'application/octet-stream'
}

export function createCore({ mesh, dbName = 'ripplo', state = createState(), notifier = notify, timing = {}, audio = { supported: audioSupported, create: createAudio } }) {
  const T = { ...DEFAULT_TIMING, ...timing }
  let db = null
  let own = null
  let me = null
  let unsubs = []
  let queue = Promise.resolve()
  let pending = {}
  let discover = null
  let tokens = { pending: [], used: {} }
  let unsent = new Set()
  let unsends = []
  let flushing = false
  let silentNow = false
  let searchText = ''
  let peopleBase = null
  const loaded = new Set()
  const waits = new Map()
  const proofs = new Map()
  const running = new Map()
  const seenIds = new Set()
  const lastReset = new Map()
  const helloCards = new Map()
  const greeted = new Set()
  const byed = new Set()
  const lastResend = new Map()
  const lastTyping = new Map()
  const typingTimers = new Map()

  const enqueue = (fn) => { queue = queue.then(fn).catch(() => {}) }

  const persistContact = (c) => db.put('contacts', c.id, { ...c })
  const persistChat = (c) => db.put('chats', c.id, { ...c })
  const persistMsg = (m) => (m.unsent ? Promise.resolve() : db.putMsg({ ...m, att: m.att && { ...m.att, url: undefined } }))
  const tagOf = (c) => deriveIds(unb64(c.ik)).tag
  // Node id (hex link tag) of a contact, as used by state.neighbors[].node; null if unknown.
  const nodeOf = (id) => (state.contacts[id]?.ik ? hex(tagOf(state.contacts[id])) : null)
  const fmtDur = (ms) => {
    const s = Math.round(ms / 1000)
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
  }
  const persistTokens = () => db.put('kv', 'tokens', { pending: tokens.pending, used: tokens.used })

  const consented = (c) => !!c && !c.request && (c.addedVia !== 'incoming' || !!c.cardSent)

  function tellVerified(c) {
    if (!consented(c)) return
    const fail = () => { c.vfSent = '?' }
    buildPacket(c, { t: 'profile' }).then(transmit).then((r) => { if (!r.ok) fail() }).catch(fail)
  }

  function newInviteLink() {
    const raw = random(8)
    tokens.pending.push(b64url(raw))
    if (tokens.pending.length > MAX_TOKENS) tokens.pending.shift()
    persistTokens().catch(() => {})
    return encodeLink(me.card, raw)
  }

  async function redeem(f, tk) {
    const i = tokens.pending.indexOf(tk)
    if (i >= 0) {
      tokens.pending.splice(i, 1)
      tokens.used[tk] = f
      const keys = Object.keys(tokens.used)
      if (keys.length > MAX_USED) delete tokens.used[keys[0]]
      await persistTokens()
    } else if (tokens.used[tk] !== f) {
      return
    }
    const c = state.contacts[f]
    if (c && !c.request && c.addedVia === 'incoming') {
      c.addedVia = 'link'
      await persistContact(c)
    }
  }

  const canCall = (c) => consented(c)
  const neighborOf = (id, node) =>
    (node && state.neighbors.find((n) => n.node === node)) ||
    state.neighbors.find((n) => n.card?.id === id) ||
    state.neighbors.find((n) => n.node && n.node === state.contacts[id]?.node)
  const callTiming = Object.fromEntries(Object.entries({ ring: timing.callRing, silence: timing.callSilence, hold: timing.callHold, warn: timing.callWarn, gone: timing.callGone }).filter(([, v]) => v !== undefined))
  const calls = createCalls({
    state,
    timing: callTiming,
    supported: audio.supported,
    newAudio: audio.create,
    ensureMic: audio.ensureMic || (async () => {
      if (!mesh.isNative) return
      const p = await mesh.checkPermissions()
      if (p && p.microphone && p.microphone !== 'granted') {
        const r = await mesh.requestPermissions()
        if (r.microphone !== 'granted') throw new Error('mic')
      }
    }),
    hasNeighbor: (id, node) => !!neighborOf(id, node),
    sendMedia: (id, bytes, node) => {
      const nb = neighborOf(id, node)
      if (!nb) return false
      mesh.sendApp(nb.node, bytes).catch(() => {})
      return true
    },
    signal: async (id, body) => {
      const c = state.contacts[id]
      if (!c || c.request) return { ok: false }
      try { return await transmit(await buildPacket(c, body)) } catch { return { ok: false } }
    },
    notify: (id) => { if (!silentNow) notifier({ title: state.contacts[id]?.name || '', body: t('incomingCall') }) },
    log: (id, reason, ms) => {
      if (!state.contacts[id]) return
      const text = reason === 'ended' ? t('callLog', { time: fmtDur(ms) }) : t('call_' + reason)
      const m = addMsg({ id: hex(random(16)), chatId: id, from: 'system', ts: Date.now(), status: 'received', text })
      touchChat(id, text, m.ts)
    },
  })

  function loadMe(name, avatar = '') {
    const { tag, ripploId } = deriveIds(own.ik)
    me = { ik: own.ik, tag, id: ripploId, name, avatar, avVer: avatar ? hex(sha256(utf8(avatar))).slice(0, 8) : '', card: encodeCard(name, own.bundle) }
    state.profile = { name, ripploId, tag: hex(tag), avatar }
  }

  async function init() {
    const vault = await createVault(mesh)
    state.insecureStorage = vault.insecure
    state.devCrypto = !!mesh.devCrypto
    own = await mesh.signalInit()
    db = await openDb(dbName, vault, mesh)
    Object.assign(state.settings, (await db.get('kv', 'settings')) || {})
    state.contacts = Object.fromEntries((await db.all('contacts')).map(([id, c]) => [id, { ...c, verifyState: 'idle' }]))
    state.chats = (await db.all('chats')).map(([, c]) => c).sort((a, b) => b.lastTs - a.lastTs)
    pending = (await db.get('kv', 'pending')) || {}
    tokens = (await db.get('kv', 'tokens')) || { pending: [], used: {} }
    unsent = new Set((await db.get('kv', 'unsent')) || [])
    unsends = (await db.get('kv', 'unsends')) || []
    state.peopleRefreshedAt = (await db.get('kv', 'peopleRefreshedAt')) || 0
    const profile = await db.get('kv', 'profile')
    state.needsOnboarding = !profile
    if (profile) {
      loadMe(profile.name, profile.avatar)
      await dropExpired()
      await start()
      if (await db.get('kv', 'needsSessionReset')) {
        for (const c of Object.values(state.contacts)) await resetSession(c).catch(() => {})
        await db.del('kv', 'needsSessionReset')
      }
    }
    state.ready = true
  }

  async function createProfile(name) {
    const clean = cleanName(name)
    if (!clean) throw new RipploError('bad_name')
    await db.put('kv', 'profile', { name: clean })
    loadMe(clean)
    state.needsOnboarding = false
    await start()
  }

  function pushProfile() {
    for (const n of state.neighbors) sendHello(n.node, false)
    for (const c of Object.values(state.contacts)) {
      if (!consented(c)) continue
      const fail = () => { c.avSent = c.nameSent = c.vfSent = '?' }
      buildPacket(c, { t: 'profile' }).then(transmit).then((r) => { if (!r.ok) fail() }).catch(fail)
    }
  }

  async function setAvatar(avatar) {
    if (avatar && !isAvatar(avatar)) throw new RipploError('bad_avatar')
    loadMe(me.name, avatar || '')
    await db.put('kv', 'profile', { name: me.name, avatar: me.avatar })
    pushProfile()
  }

  async function setName(name) {
    const clean = cleanName(name)
    if (!clean) throw new RipploError('bad_name')
    if (clean === me.name) return
    loadMe(clean, me.avatar)
    await db.put('kv', 'profile', { name: me.name, avatar: me.avatar })
    pushProfile()
  }

  async function start() {
    unsubs.push(mesh.on('packet', ({ packet, from }) => onPacket(packet, from)))
    unsubs.push(mesh.on('neighbor', onNeighbor))
    unsubs.push(mesh.on('opened', (rec) => enqueue(() => handleOpened(rec))))
    await mesh.start(me.tag)
    for (const n of (await mesh.getNeighbors()) || []) onNeighbor({ ...n, up: true })
    for (const item of (await mesh.drainInbox()) || []) {
      if (item.opened) enqueue(() => handleOpened(item.opened))
      else onPacket(item.packet, item.from)
    }
    flushUnsends()
  }

  function close() {
    unsubs.forEach((u) => u && u())
    unsubs = []
    waits.forEach((w) => clearTimeout(w.timer))
    waits.clear()
    typingTimers.forEach((tm) => clearTimeout(tm))
    typingTimers.clear()
    return db && db.close()
  }

  function sendHello(node, ask) {
    if (state.settings.hidden) {
      const id = (state.neighbors.find((n) => n.node === node)?.card || helloCards.get(node))?.id
      if (!id || !state.contacts[id] || state.contacts[id].request) return
    }
    greeted.add(node)
    diagLog('hello out ' + node.slice(0, 8) + (ask ? ' ask' : ''))
    mesh.sendApp(node, utf8(JSON.stringify({ t: 'hello', card: b64(me.card), ...(ask && { r: 1 }) }))).catch(() => {})
  }

  function askCard(node, n) {
    later(Math.min(T.helloRetry * 2 ** n, 60000), () => {
      const nb = state.neighbors.find((x) => x.node === node)
      if (!nb || nb.card || byed.has(node)) return
      sendHello(node, true)
      askCard(node, n + 1)
    })
  }

  function later(ms, fn) {
    const timer = setTimeout(fn, ms)
    if (timer.unref) timer.unref()
  }

  function onNeighbor({ node, up, medium, kbps, rttMs }) {
    diagLog('neighbor ' + (up ? 'up ' : 'down ') + node.slice(0, 8) + ' ' + medium + ' ' + kbps + 'kbps')
    const i = state.neighbors.findIndex((n) => n.node === node)
    if (!up) {
      if (i >= 0) state.neighbors.splice(i, 1)
      helloCards.delete(node)
      greeted.delete(node)
      byed.delete(node)
      return
    }
    if (i >= 0) Object.assign(state.neighbors[i], { medium, kbps, rttMs })
    else {
      state.neighbors.push({ node, medium, kbps, rttMs })
      askCard(node, 0)
      flushUnsends()
    }
    mesh.getNeighbors().then((all) => {
      const fresh = (all || []).find((x) => x.node === node)
      const cur = state.neighbors.find((n) => n.node === node)
      if (fresh?.links && cur) cur.links = fresh.links
    }).catch(() => {})
    const nb = state.neighbors.find((n) => n.node === node)
    if (!nb.card && helloCards.has(node)) nb.card = helloCards.get(node)
    sendHello(node, !nb.card)
  }

  function onPacket(bytes, from) {
    let p
    try { p = decodePacket(bytes) } catch { return }
    const id = hex(p.id)
    switch (p.type) {
      case TYPE.DATA:
        if (seenIds.has(id)) return
        seenIds.add(id)
        if (seenIds.size > 2000) seenIds.delete(seenIds.values().next().value)
        if (p.payload[0] === 2) enqueue(() => onChunk(p))
        else if (p.payload[0] === 1 || (mesh.devCrypto && p.payload[0] === 0xee)) enqueue(() => onSealed(p.payload))
        break
      case TYPE.ACK: settle(hex(p.dest), { ok: true, hops: p.hops }); break
      case TYPE.DEAD_END:
        if (discover && hex(p.dest) === discover.id) discover.settle()
        else settle(hex(p.dest), { ok: false })
        break
      case TYPE.DISCOVER: onDiscover(p); break
      case TYPE.REPLY: onReply(p); break
      case TYPE.APP: onApp(p, from).catch(() => {}); break
    }
  }

  function transmit(pkt, ms = T.ack) {
    const id = pktId(pkt)
    return new Promise((resolve) => {
      const timer = setTimeout(() => settle(id, { ok: false }), ms)
      waits.set(id, { resolve, timer })
      mesh.send(pkt).catch(() => settle(id, { ok: false, error: true }))
    })
  }

  function settle(id, result) {
    const w = waits.get(id)
    if (!w) return
    clearTimeout(w.timer)
    waits.delete(id)
    w.resolve(result)
  }

  async function resetSession(c) {
    if (!c.card || Date.now() - (lastReset.get(c.id) || 0) < RESET_GAP) return false
    lastReset.set(c.id, Date.now())
    const v = checkCard(unb64(c.card))
    await mesh.signalForget(hex(tagOf(c))).catch(() => {})
    await mesh.signalAddContact(v.bundle)
    buildPacket(c, { t: 'reset' }).then(transmit).catch(() => {})
    return true
  }

  async function restoreBackup(code) {
    const r = await mesh.backupRestore({ code })
    const d = await openDb(dbName, await createVault(mesh), mesh)
    await d.put('kv', 'needsSessionReset', { at: Date.now() })
    await d.close()
    return r
  }

  async function buildPacket(c, extra, bare = false) {
    let obj = extra
    if (bare) {
      const payload = await mesh.signalSeal(hex(tagOf(c)), utf8(JSON.stringify(obj)))
      return encodePacket({ type: TYPE.DATA, dest: tagOf(c), payload })
    }
    if (!c.cardAck) {
      obj = { ...extra, c: b64(me.card), ...(c.token && { tk: c.token }) }
      if (!c.cardSent) { c.cardSent = Date.now(); persistContact(c) }
    }
    if ((me.avatar || c.avSent) && c.avSent !== me.avVer) {
      obj = { ...obj, av: me.avatar }
      c.avSent = me.avVer
      persistContact(c)
    }
    if (c.nameSent !== me.name) {
      obj = { ...obj, nm: me.name }
      c.nameSent = me.name
      persistContact(c)
    }
    if (c.verification !== 'none' && c.vfSent !== c.verification) {
      obj = { ...obj, vf: c.verification }
      c.vfSent = c.verification
      persistContact(c)
    }
    const payload = await mesh.signalSeal(hex(tagOf(c)), utf8(JSON.stringify(obj)))
    return encodePacket({ type: TYPE.DATA, dest: tagOf(c), payload })
  }

  function touchChat(chatId, text, ts, unread = 0, lastKind = null) {
    const chat = state.chats.find((c) => c.id === chatId)
    if (!chat) return
    Object.assign(chat, { lastText: text, lastKind, lastTs: ts, unread: chat.unread + unread })
    state.chats.sort((a, b) => b.lastTs - a.lastTs)
    persistChat(chat)
  }

  function ensureChat(id, type, name, members) {
    let chat = state.chats.find((c) => c.id === id)
    if (!chat) {
      chat = { id, type, name, lastText: '', lastTs: Date.now(), unread: 0 }
      if (members) chat.members = members
      state.chats.push(chat)
      chat = state.chats[state.chats.length - 1]
    } else {
      chat.name = name
      if (members) chat.members = members
    }
    persistChat(chat)
    return chat
  }

  function addMsg(m) {
    const list = (state.messages[m.chatId] ??= [])
    list.push(m)
    persistMsg(m)
    return list[list.length - 1]
  }

  function recipientsOf(chatId) {
    let chat = state.chats.find((c) => c.id === chatId)
    if (state.contacts[chatId]?.request) throw new RipploError('no_chat')
    if (!chat && state.contacts[chatId]) chat = ensureChat(chatId, 'direct', state.contacts[chatId].name)
    if (!chat) throw new RipploError('no_chat')
    return chat.type === 'group' ? [...chat.members] : [chatId]
  }

  function fanout(m, body, recips) {
    m.status = 'sending'
    persistMsg(m)
    return Promise.all(recips.map(async (rid) => {
      let r
      try { r = await transmit(await buildPacket(state.contacts[rid], body)) } catch { r = { ok: false, error: true } }
      if (r.ok) {
        m.undelivered = m.undelivered.filter((x) => x !== rid)
        m.delivered = m.total - m.undelivered.length
        m.hops = r.hops
      } else if (r.error) m.errored = true
      if (!r.ok) state.contacts[rid].avSent = state.contacts[rid].nameSent = state.contacts[rid].vfSent = '?'
    })).then(() => {
      m.status = m.undelivered.length === 0 ? 'delivered' : m.errored ? 'failed' : 'out_of_range'
      persistMsg(m)
    })
  }

  function newOutgoing(chatId, extra) {
    const recips = recipientsOf(chatId)
    const m = addMsg({
      id: hex(random(16)), chatId, from: 'me', ts: Date.now(), status: 'encrypting',
      undelivered: [...recips], delivered: 0, total: recips.length, ...extra,
    })
    return { m, recips }
  }

  const wireRe = (r) => ({ id: r.id, who: r.who, ...(r.text && { text: r.text }), ...(r.kind && { kind: r.kind }) })
  const textBody = (m, group) => ({ t: 'msg', id: m.id, text: m.text, ts: m.ts, ...(group && { g: group }), ...(m.re && { re: wireRe(m.re) }) })

  function localRef(chatId, localId) {
    const m = (state.messages[chatId] || []).find((x) => x.id === localId)
    if (!m || m.from === 'system') return undefined
    const mine = m.from === 'me'
    return {
      id: mine ? m.id : m.id.slice(m.id.indexOf('.') + 1), who: mine ? me.id : m.from, mid: m.id,
      ...(m.text && { text: m.text.slice(0, RE_TEXT) }), ...(m.att && { kind: m.att.kind }),
    }
  }

  function parseRe(raw) {
    if (!raw || typeof raw !== 'object' || !WIRE_ID_RE.test(raw.id) || !ID_RE.test(raw.who)) return undefined
    const out = { id: raw.id, who: raw.who, mid: raw.who === me.id ? raw.id : `${raw.who}.${raw.id}` }
    if (typeof raw.text === 'string') out.text = raw.text.slice(0, RE_TEXT)
    if (KINDS.includes(raw.kind)) out.kind = raw.kind
    return out
  }

  const captionOf = (v) => (typeof v === 'string' && v.length <= MAX_TEXT && v.trim() ? v : undefined)
  const groupOf = (chatId) => (state.chats.find((c) => c.id === chatId)?.type === 'group' ? chatId : undefined)

  // Developer log transfer: sent as an encrypted one-to-one packet (no chat entry on either side).
  const DLOG_BODY_MAX = 45000
  async function packLog(text) {
    if (typeof CompressionStream === 'undefined') return { raw: text.slice(-30000) }
    const gz = await new Response(new Blob([utf8(text)]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer()
    return { z: b64(new Uint8Array(gz)) }
  }
  async function unpackLog(body) {
    if (typeof body.raw === 'string') return body.raw
    if (typeof body.z !== 'string' || typeof DecompressionStream === 'undefined') return null
    return new Response(new Blob([unb64(body.z)]).stream().pipeThrough(new DecompressionStream('gzip'))).text()
  }
  async function sendDevLog(to, text) {
    const c = state.contacts[to]
    if (!c || c.request) throw new RipploError('no_chat')
    const body = { t: 'dlog', id: hex(random(16)), ts: Date.now(), ...(await packLog(text)) }
    if (body.z && body.z.length > DLOG_BODY_MAX) throw new RipploError('too_big')
    const r = await transmit(await buildPacket(c, body))
    return { ok: !!r.ok, hops: r.hops }
  }
  function deleteDevLog(id) {
    state.devLogs = state.devLogs.filter((x) => x.id !== id)
  }

  async function sendText(chatId, text, replyTo) {
    if (typeof text !== 'string' || !text.trim()) throw new RipploError('empty')
    if (text.length > MAX_TEXT) throw new RipploError('too_long')
    const re = replyTo ? localRef(chatId, replyTo) : undefined
    const { m, recips } = newOutgoing(chatId, { text, ...(re && { re }) })
    touchChat(chatId, text, m.ts)
    fanout(m, textBody(m, groupOf(chatId)), recips).catch(() => {})
    return m
  }

  async function sendAttachment(chatId, file, kind, meta = {}) {
    if (!KINDS.includes(kind)) throw new RipploError('bad_kind')
    if (file.size > MAX_FILE) throw new RipploError('too_big')
    const peer = state.contacts[chatId]
    if (peer && peer.addedVia !== 'incoming' && !peer.cardAck) throw new RipploError('media_locked')
    const bytes = new Uint8Array(await file.arrayBuffer())
    const attId = hex(random(16))
    await db.putBin('blobs', attId, bytes)
    const att = { kind, mime: safeMime(file.type), size: bytes.length, attId, url: URL.createObjectURL(file) }
    const duration = meta.duration ?? file.duration
    if (Number.isFinite(duration) && duration > 0) att.duration = Math.min(duration, 3600)
    if (Array.isArray(meta.wave) && meta.wave.length <= MAX_WAVE) att.wave = meta.wave.map((v) => Math.max(0, Math.min(255, v | 0)))
    if (meta.caption && !captionOf(meta.caption)) throw new RipploError('too_long')
    const caption = captionOf(meta.caption)
    const re = meta.replyTo ? localRef(chatId, meta.replyTo) : undefined
    const { m, recips } = newOutgoing(chatId, { att, progress: 0, ...(caption && { text: caption }), ...(re && { re }) })
    touchChat(chatId, caption || '', m.ts, 0, kind)
    runAttachment(m, bytes, recips).catch(() => { m.status = 'failed'; persistMsg(m) })
    return m
  }

  async function runAttachment(m, bytes, recips) {
    m.status = 'encrypting'
    m.progress = 0
    const { ct, key, sha256: hash } = await encryptFile(bytes)
    const attId = newId()
    const total = chunkCount(ct)
    const all = total * recips.length
    let acked = 0
    m.status = 'sending'
    const okRecips = []
    await Promise.all(recips.map(async (rid) => {
      const dest = tagOf(state.contacts[rid])
      let next = 0
      let failed = false
      const sendChunk = async (i) => {
        for (let k = 0; k < T.tries; k++) {
          const r = await transmit(encodePacket({ type: TYPE.DATA, dest, payload: chunkPayload(attId, ct, i, total) }), T.chunkAck)
          if (r.ok) return true
          if (k + 1 < T.tries) await sleep(T.retry)
        }
        return false
      }
      const worker = async () => {
        while (!failed && next < total) {
          const i = next++
          if (!(await sendChunk(i))) { failed = true; return }
          acked++
          m.progress = acked / all
        }
      }
      await Promise.all(Array.from({ length: Math.min(WINDOW, total) }, worker))
      if (!failed) okRecips.push(rid)
    }))
    const g = groupOf(m.chatId)
    const body = {
      t: 'att', id: m.id, attId: hex(attId), kind: m.att.kind, mime: m.att.mime, size: m.att.size,
      sha256: hex(hash), key: b64(key), chunks: total, ts: m.ts, ...(g && { g }), ...(m.att.duration && { duration: m.att.duration }), ...(m.att.wave && { wave: b64(Uint8Array.from(m.att.wave)) }),
      ...(m.text && { text: m.text }), ...(m.re && { re: wireRe(m.re) }),
    }
    await fanout(m, body, okRecips)
  }

  async function retry(msgId) {
    const m = Object.values(state.messages).flat().find((x) => x.id === msgId)
    if (!m || m.from !== 'me' || !['out_of_range', 'failed'].includes(m.status)) return
    const recips = m.undelivered.length ? [...m.undelivered] : recipientsOf(m.chatId)
    m.errored = false
    if (!m.att) fanout(m, textBody(m, groupOf(m.chatId)), recips).catch(() => {})
    else runAttachment(m, await db.getBin('blobs', m.att.attId), recips).catch(() => { m.status = 'failed'; persistMsg(m) })
  }

  function resendFor(id) {
    if (Date.now() - (lastResend.get(id) || 0) < T.resend) return
    lastResend.set(id, Date.now())
    for (const list of Object.values(state.messages)) {
      for (const m of list) {
        if (m.from === 'me' && ['out_of_range', 'failed'].includes(m.status) && m.undelivered?.includes(id)) retry(m.id).catch(() => {})
      }
    }
  }

  function clearTyping(chatId, from) {
    const k = `${chatId}/${from}`
    clearTimeout(typingTimers.get(k))
    typingTimers.delete(k)
    if (state.typing[chatId]?.includes(from)) state.typing = { ...state.typing, [chatId]: state.typing[chatId].filter((x) => x !== from) }
  }

  function onTyping(c, msg) {
    if (Number.isFinite(msg.ts) && Date.now() - msg.ts > T.typingTtl) return
    const chatId = routeChat(c.id, msg.g)
    if (!chatId) return
    const k = `${chatId}/${c.id}`
    clearTimeout(typingTimers.get(k))
    const list = state.typing[chatId] || []
    if (!list.includes(c.id)) state.typing = { ...state.typing, [chatId]: [...list, c.id] }
    const timer = setTimeout(() => clearTyping(chatId, c.id), T.typingTtl)
    if (timer.unref) timer.unref()
    typingTimers.set(k, timer)
  }

  async function sendTyping(chatId) {
    const now = Date.now()
    if (now - (lastTyping.get(chatId) || 0) < T.typing) return
    let recips
    try { recips = recipientsOf(chatId) } catch { return }
    lastTyping.set(chatId, now)
    const g = groupOf(chatId)
    const body = utf8(JSON.stringify({ t: 'typing', ts: now, ...(g && { g }) }))
    for (const rid of recips) {
      const c = state.contacts[rid]
      const nb = c && c.cardAck && !c.request && neighborOf(rid, c.node)
      if (!nb) continue
      try { await mesh.sendApp(nb.node, concat(Uint8Array.of(TYPING_TAG), await mesh.signalSeal(hex(tagOf(c)), body))) } catch {}
    }
  }

  async function onSealed(payload) {
    let r
    try { r = await mesh.signalOpen(payload) } catch (e) { return onOpenFailed(e) }
    await processOpened(r, false)
  }

  async function handleOpened(rec) {
    let r
    try { r = { tag: String(rec.tag), ik: unb64(rec.ik), plaintext: unb64(rec.plaintext) } } catch { return }
    await processOpened(r, !!rec.notified)
  }

  async function processOpened(r, silent) {
    silentNow = silent
    try {
      await processOpenedInner(r)
    } finally {
      silentNow = false
    }
  }

  async function processOpenedInner(r) {
    const { tag, ik, plaintext } = r
    const ids = deriveIds(ik)
    const f = ids.ripploId
    if (hex(ids.tag) !== tag || f === me.id) return
    const msg = JSON.parse(unutf8(plaintext))
    if (msg?.t === 'typing') {
      const peer = state.contacts[f]
      if (peer && !peer.request) onTyping(peer, msg)
      return
    }
    if (!state.contacts[f]) {
      const asking = msg?.t === 'invite'
      if (asking && state.settings.hidden) return
      await addContact({ id: f, name: knownName(f) || `Ripplo ${f.slice(0, 4)}`, ik: b64(ik), card: null, addedVia: 'incoming', ...(asking && { request: 'in' }) })
    }
    const c = state.contacts[f]
    const fresh = c.request === 'in' && !c.notified
    if (c.cardSent && !c.cardAck) { c.cardAck = true; delete c.token; persistContact(c) }
    if (typeof msg?.tk === 'string' && TOKEN_RE.test(msg.tk)) await redeem(f, msg.tk)
    if (typeof msg?.av === 'string' && (msg.av === '' || isAvatar(msg.av)) && (c.avatar || '') !== msg.av) {
      c.avatar = msg.av
      await persistContact(c)
    }
    if (msg && typeof msg.c === 'string' && !c.card) {
      try {
        const v = checkCard(unb64(msg.c))
        if (v.id === f) await learnCard(v, 'incoming')
      } catch {}
    }
    if (msg && typeof msg.c === 'string' && c.card && c.cardAck && !c.request) {
      c.avSent = c.nameSent = c.vfSent = undefined
      tellVerified(c)
    }
    if (typeof msg?.vf === 'string' && ['nearby', 'qr', 'manual'].includes(msg.vf) && c.peerVerified?.level !== msg.vf) {
      c.peerVerified = { level: msg.vf, at: Date.now() }
      await persistContact(c)
    }
    const nm = typeof msg?.nm === 'string' ? cleanName(msg.nm) : ''
    if (nm && nm !== c.name) {
      c.name = nm
      if (!c.request) ensureChat(c.id, 'direct', nm)
      markConflicts(nm, c.id)
      await persistContact(c)
    }
    if (c.request === 'in') {
      if (msg?.t !== 'invite') return
      if (fresh) {
        c.notified = true
        await persistContact(c)
        if (!silentNow) notifier({ title: t('inviteNotifyTitle'), body: t('inviteNotifyBody', { name: c.name }) })
      }
      return
    }
    if (c.request === 'out') {
      if (msg?.t === 'decline') { await deleteContact(f); return }
      await becomeContact(c, 'people')
      if (msg?.t === 'invite') buildPacket(c, { t: 'accept' }).then(transmit).catch(() => {})
    }
    await onAppMessage(f, msg)
  }

  async function onOpenFailed(e) {
    const tag = e?.data?.tag || e?.tag
    if (!['bad_message', 'no_session'].includes(e?.code) || !tag) return
    const c = Object.values(state.contacts).find((x) => hex(tagOf(x)) === tag)
    if (!c || !(await resetSession(c))) return
    const text = t('undecryptable', { name: c.name })
    const m = addMsg({ id: hex(random(16)), chatId: c.id, from: 'system', ts: Date.now(), status: 'received', text })
    touchChat(c.id, text, m.ts)
  }

  const knownName = (id) => state.neighbors.find((n) => n.card?.id === id)?.card.name || state.people.find((p) => p.id === id)?.name

  function routeChat(f, g) {
    if (g === undefined) return f
    const chat = state.chats.find((c) => c.id === g)
    return chat && chat.type === 'group' && chat.members.includes(f) ? g : null
  }

  async function onAppMessage(f, msg) {
    if (!msg || typeof msg !== 'object') return
    if (msg.t === 'msg') {
      if (!WIRE_ID_RE.test(msg.id) || typeof msg.text !== 'string' || msg.text.length > MAX_TEXT) return
      const chatId = routeChat(f, msg.g)
      if (!chatId) return
      const re = parseRe(msg.re)
      await receive({ id: `${f}.${msg.id}`, chatId, from: f, text: msg.text, ...(re && { re }) }, msg.text)
    } else if (msg.t === 'att') {
      const sender = state.contacts[f]
      if (sender && sender.addedVia === 'incoming' && !sender.cardSent) return
      if (!WIRE_ID_RE.test(msg.id) || !/^[0-9a-f]{32}$/.test(msg.attId) || !KINDS.includes(msg.kind) || !/^[0-9a-f]{64}$/.test(msg.sha256)) return
      if (!Number.isInteger(msg.size) || msg.size < 0 || msg.size > MAX_FILE || !Number.isInteger(msg.chunks) || msg.chunks < 1 || msg.chunks > MAX_CHUNKS) return
      if (typeof msg.key !== 'string' || unb64(msg.key).length !== 32 || !routeChat(f, msg.g)) return
      await db.put('kv', `ptr/${msg.attId}`, { f, msg, silent: silentNow })
      await tryFinish(msg.attId)
    } else if (msg.t === 'unsend') {
      if (!WIRE_ID_RE.test(msg.id)) return
      const chatId = routeChat(f, msg.g)
      if (!chatId) return
      const localId = `${f}.${msg.id}`
      unsent.add(localId)
      if (unsent.size > MAX_UNSENT) unsent.delete(unsent.values().next().value)
      await db.put('kv', 'unsent', [...unsent])
      await removeMessage(chatId, localId)
    } else if (msg.t === 'dlog') {
      const sender = state.contacts[f]
      if (!sender || sender.request || typeof msg.id !== 'string' || msg.id.length > 64) return
      const text = await unpackLog(msg).catch(() => null)
      if (typeof text !== 'string' || text.length > 400000) return
      state.devLogs = [{ id: msg.id, from: f, name: sender.name, ts: Date.now(), text }, ...state.devLogs].slice(0, 20)
    } else if (msg.t === 'group') {
      await onGroup(f, msg)
    } else if (msg.t === 'call') {
      if (canCall(state.contacts[f])) await calls.onSignal(f, msg)
    }
  }

  async function receive(m, preview, notifyBody = preview) {
    if (unsent.has(m.id) || (await db.hasMsg(m.id))) return
    const msg = addMsg({ ...m, ts: Date.now(), status: 'received' })
    clearTyping(m.chatId, m.from)
    touchChat(m.chatId, preview, msg.ts, 1, m.att?.kind)
    const chat = state.chats.find((c) => c.id === m.chatId)
    if (!silentNow) notifier({ title: chat?.type === 'group' ? `${chat.name}: ${state.contacts[m.from]?.name}` : state.contacts[m.from]?.name, body: notifyBody, chatId: m.chatId })
  }

  async function onGroup(f, msg) {
    if (!/^[A-Za-z0-9_-]{6,32}$/.test(msg.g) || !Array.isArray(msg.members) || msg.members.length < 2 || msg.members.length > MAX_GROUP + 1) return
    const name = cleanName(msg.name)
    if (!name) return
    let cards
    try { cards = msg.members.map((m) => checkCard(unb64(m))) } catch { return }
    const ids = cards.map((c) => c.id)
    if (!ids.includes(f) || !ids.includes(me.id)) return
    const existing = state.chats.find((c) => c.id === msg.g)
    if (existing && (existing.type !== 'group' || !existing.members.includes(f))) return
    for (const v of cards) if (v.id !== me.id) await learnCard(v, 'group')
    ensureChat(msg.g, 'group', name, ids.filter((i) => i !== me.id))
  }

  async function addContact({ id, name, ik, card, addedVia, request, token }) {
    state.contacts[id] = {
      id, name, ik, card, verification: 'none', verifiedAt: 0, verifyState: 'idle',
      addedVia, addedAt: Date.now(), conflict: false, ...(request && { request }), ...(token && { token }),
    }
    const c = state.contacts[id]
    markConflicts(name, id)
    if (!request) ensureChat(id, 'direct', name)
    await persistContact(c)
    if (!request) verifyNearby(id).catch(() => {})
    return c
  }

  async function learnCard(v, via, token) {
    const c = state.contacts[v.id]
    const card = b64(v.card), ik = b64(v.ik)
    if (!c) {
      try { await mesh.signalAddContact(v.bundle) } catch { throw new RipploError('bad_link', 'invalid prekey bundle') }
      return addContact({ id: v.id, name: v.name, ik, card, addedVia: via, token })
    }
    if (token && !c.cardAck && !c.token) { c.token = token; await persistContact(c) }
    if (!c.card && c.ik === ik) {
      c.card = card
      c.name = v.name
      if (!c.request) ensureChat(c.id, 'direct', c.name)
      markConflicts(c.name, c.id)
      await persistContact(c)
    }
    return c
  }

  function markConflicts(name, id) {
    const key = name.toLowerCase()
    const same = Object.values(state.contacts).filter((c) => c.id !== id && c.name.toLowerCase() === key)
    if (!same.length) return
    same.forEach((c) => { c.conflict = true; persistContact(c) })
    const self = state.contacts[id]
    if (self) { self.conflict = true; persistContact(self) }
  }

  async function addCard(raw, via, token) {
    const v = checkCard(raw)
    if (v.id === me.id) throw new RipploError('self')
    const isNew = !state.contacts[v.id]
    const c = await learnCard(v, via, token)
    if (!isNew) {
      if (c.request === 'in') await acceptRequest(c.id)
      return c
    }
    const person = state.people.find((p) => p.id === v.id)
    if (person) person.isContact = true
    if (['link', 'qr', 'people'].includes(via)) verifyNearby(v.id).catch(() => {})
    if (['link', 'qr'].includes(via)) tellVerified(c)
    return c
  }

  async function addContactFromLink(text, via = 'link') {
    const v = parseLink(text)
    if (v.id === me.id) throw new RipploError('self')
    return addCard(v.card, via, v.token)
  }

  async function becomeContact(c, via) {
    delete c.request
    c.addedVia = via
    ensureChat(c.id, 'direct', c.name)
    await persistContact(c)
    const person = state.people.find((p) => p.id === c.id)
    if (person) person.isContact = true
    verifyNearby(c.id).catch(() => {})
  }

  async function invite(person) {
    const v = checkCard(unb64(person.card))
    if (v.id === me.id) throw new RipploError('self')
    let c = state.contacts[v.id]
    if (c?.request === 'in') return acceptRequest(c.id)
    if (c && c.request !== 'out') return c
    if (!c) {
      try { await mesh.signalAddContact(v.bundle) } catch { throw new RipploError('bad_link', 'invalid prekey bundle') }
      c = await addContact({ id: v.id, name: v.name, ik: b64(v.ik), card: b64(v.card), addedVia: 'people', request: 'out' })
    }
    c.inviteFailed = false
    persistContact(c)
    buildPacket(c, { t: 'invite' }).then(transmit).then((r) => {
      if (!r.ok && state.contacts[c.id]?.request === 'out') { c.inviteFailed = true; persistContact(c) }
    }).catch(() => { c.inviteFailed = true; persistContact(c) })
    return c
  }

  async function acceptRequest(id) {
    const c = state.contacts[id]
    if (!c || c.request !== 'in') return
    await becomeContact(c, 'people')
    buildPacket(c, { t: 'accept' }).then(transmit).catch(() => {})
    return c
  }

  async function declineRequest(id) {
    const c = state.contacts[id]
    if (!c || c.request !== 'in') return
    const pkt = await buildPacket(c, { t: 'decline' }, true)
    await deleteContact(id)
    transmit(pkt).catch(() => {})
  }

  async function onApp(p, from) {
    if (p.payload[0] === FRAME_TAG) return calls.onMedia(p.payload, from)
    if (p.payload[0] === TYPING_TAG) { enqueue(() => onSealed(p.payload.subarray(1))); return }
    const msg = JSON.parse(unutf8(p.payload))
    const nb = state.neighbors.find((n) => n.node === from)
    if (!msg || typeof msg !== 'object') return
    if (msg.t === 'hello') {
      let v
      try { v = checkCard(unb64(msg.card)) } catch {
        diagLog('hello rejected ' + from.slice(0, 8))
        if (nb) nb.unsupported = true
        return
      }
      diagLog('hello in ' + from.slice(0, 8) + ' ' + v.name + (nb ? '' : ' (no neighbor)'))
      if (nb) nb.unsupported = false
      if (v.id === me.id) return
      const card = { id: v.id, name: v.name, ik: b64(v.ik), card: b64(v.card) }
      if (helloCards.size >= MAX_HELLOS && !helloCards.has(from)) helloCards.delete(helloCards.keys().next().value)
      helloCards.set(from, card)
      byed.delete(from)
      if (nb) nb.card = card
      markConflicts(v.name, v.id)
      if (state.contacts[v.id]) await learnCard(v, 'link')
      const known = state.contacts[v.id]
      if (known && known.node !== from) {
        known.node = from
        persistContact(known)
      }
      if (known && !known.request) resendFor(known.id)
      if (known && !known.request && known.verification === 'none' && known.verifyState !== 'checking' && Date.now() - (known.verifyTried || 0) > 30000) {
        known.verifyTried = Date.now()
        verifyNearby(v.id).catch(() => {})
      }
      if (msg.r || (state.settings.hidden && !greeted.has(from))) sendHello(from, false)
    } else if (!nb) {
      return
    } else if (msg.t === 'bye') {
      diagLog('bye in ' + from.slice(0, 8))
      byed.add(from)
      helloCards.delete(from)
      greeted.delete(from)
      const known = nb.card && state.contacts[nb.card.id]
      if (!known || known.request) delete nb.card
    } else if (msg.t === 'challenge') {
      const n = unb64(msg.n)
      const ik = nb.card && nb.card.id === msg.from ? unb64(nb.card.ik) : state.contacts[msg.from] && unb64(state.contacts[msg.from].ik)
      if (n.length !== 32 || !ik || deriveIds(ik).ripploId !== msg.from) return
      const mac = await mesh.signalProof(ik, n, deriveIds(ik).tag, me.tag)
      await mesh.sendApp(from, utf8(JSON.stringify({ t: 'proof', n: msg.n, mac: b64(mac) })))
    } else if (msg.t === 'proof') {
      const w = proofs.get(msg.n)
      if (!w || w.node !== from) return
      proofs.delete(msg.n)
      w.resolve(unb64(String(msg.mac)))
    }
  }

  async function proveOnce(c, node) {
    const n = random(32)
    const key = b64(n)
    const answer = new Promise((resolve) => {
      const timer = setTimeout(() => { proofs.delete(key); resolve(null) }, T.proof)
      proofs.set(key, { node, resolve: (mac) => { clearTimeout(timer); resolve(mac) } })
    })
    try { await mesh.sendApp(node, utf8(JSON.stringify({ t: 'challenge', n: key, from: me.id }))) } catch { return 'timeout' }
    const mac = await answer
    if (!mac) return 'timeout'
    const ik = unb64(c.ik)
    return equal(mac, await mesh.signalProof(ik, n, me.tag, deriveIds(ik).tag)) ? 'ok' : 'bad'
  }

  function verifyNearby(id) {
    if (running.has(id)) return running.get(id)
    const job = (async () => {
      const c = state.contacts[id]
      if (!c) return false
      c.verifyState = 'checking'
      const end = Date.now() + T.verify
      let ok = false
      while (Date.now() < end && state.contacts[id]) {
        const nb = state.neighbors.find((n) => n.card && n.card.id === id)
        if (nb) {
          const r = await proveOnce(c, nb.node)
          if (r === 'ok') { ok = true; break }
          if (r === 'bad') { c.conflict = true; break }
        }
        await sleep(T.poll)
      }
      const cur = state.contacts[id]
      if (!cur) return false
      if (ok) {
        if (cur.verification === 'none' || cur.verification === 'nearby') cur.verification = cur.addedVia === 'qr' ? 'qr' : 'nearby'
        cur.verifiedAt = Date.now()
        cur.verifyState = 'idle'
      } else cur.verifyState = 'failed'
      await persistContact(cur)
      if (ok) tellVerified(cur)
      return ok
    })().finally(() => running.delete(id))
    running.set(id, job)
    return job
  }

  async function removeMessage(chatId, localId) {
    const list = state.messages[chatId] || []
    const i = list.findIndex((x) => x.id === localId)
    const m = i >= 0 ? list[i] : (await db.msgs(chatId)).find((x) => x.id === localId)
    if (m) m.unsent = true
    if (i >= 0) list.splice(i, 1)
    if (m?.att) {
      await db.del('blobs', m.att.attId)
      if (m.att.url) URL.revokeObjectURL(m.att.url)
    }
    await db.delMsg(localId)
    for (const x of list) {
      if (x.re?.mid === localId && (x.re.text || x.re.kind)) {
        delete x.re.text
        delete x.re.kind
        persistMsg(x)
      }
    }
    const chat = state.chats.find((c) => c.id === chatId)
    if (chat) {
      const remaining = state.messages[chatId] ?? (await db.msgs(chatId)).sort((a, b) => a.ts - b.ts)
      const last = remaining[remaining.length - 1]
      Object.assign(chat, { lastText: last?.text || '', lastKind: last?.att?.kind || null, lastTs: last?.ts || chat.lastTs })
      persistChat(chat)
    }
  }

  async function flushUnsends() {
    if (flushing) return
    flushing = true
    try {
      for (const u of [...unsends]) {
        for (const rid of [...u.to]) {
          const c = state.contacts[rid]
          if (!c || c.request) { u.to = u.to.filter((x) => x !== rid); continue }
          let r
          try { r = await transmit(await buildPacket(c, { t: 'unsend', id: u.id, ...(u.g && { g: u.g }) })) } catch { r = { ok: false } }
          if (r.ok) u.to = u.to.filter((x) => x !== rid)
        }
      }
      unsends = unsends.filter((u) => u.to.length)
      await db.put('kv', 'unsends', unsends)
    } finally {
      flushing = false
    }
  }

  async function unsendMessage(chatId, localId) {
    const m = (state.messages[chatId] || []).find((x) => x.id === localId && x.from === 'me')
    if (!m) throw new RipploError('no_message')
    const recips = recipientsOf(chatId)
    const g = groupOf(chatId)
    await removeMessage(chatId, localId)
    unsends.push({ id: localId, ...(g && { g }), to: recips })
    await db.put('kv', 'unsends', unsends)
    flushUnsends()
  }

  async function setVerified(id, level) {
    const c = state.contacts[id]
    if (!c) return false
    Object.assign(c, { verification: level, verifiedAt: Date.now(), verifyState: 'idle' })
    await persistContact(c)
    tellVerified(c)
    return true
  }

  async function verifyByQr(id, scanned) {
    const c = state.contacts[id]
    if (!c) return false
    const text = String(scanned)
    const digits = text.replace(/\s+/g, '')
    if (/^\d{60}$/.test(digits)) return digits === (await safetyNumber(id)) && setVerified(id, 'qr')
    try {
      const v = parseLink(text)
      return b64(v.ik) === c.ik && (await setVerified(id, 'qr'))
    } catch {
      return false
    }
  }

  const markVerified = (id) => setVerified(id, 'manual').then(() => {})

  async function safetyNumber(id) {
    const c = state.contacts[id]
    if (!c) throw new RipploError('no_contact')
    return mesh.signalSafetyNumber(unb64(c.ik))
  }

  async function loadMessages(chatId) {
    if (loaded.has(chatId)) return state.messages[chatId]
    loaded.add(chatId)
    const mem = new Map((state.messages[chatId] || []).map((m) => [m.id, m]))
    const rows = await db.msgs(chatId)
    for (const m of rows) {
      if (m.att && !m.att.url) {
        const bytes = await db.getBin('blobs', m.att.attId)
        if (bytes) m.att.url = URL.createObjectURL(new Blob([bytes], { type: m.att.mime }))
      }
    }
    state.messages[chatId] = rows.map((m) => mem.get(m.id) || m)
    return state.messages[chatId]
  }

  function markRead(chatId) {
    const chat = state.chats.find((c) => c.id === chatId)
    if (chat && chat.unread) { chat.unread = 0; persistChat(chat) }
  }

  async function createGroup(name, memberIds) {
    const clean = cleanName(name)
    const ids = [...new Set(memberIds)]
    if (!clean || !ids.length) throw new RipploError('bad_group')
    if (ids.length > MAX_GROUP) throw new RipploError('too_many')
    if (ids.some((i) => !state.contacts[i] || !state.contacts[i].card || state.contacts[i].request)) throw new RipploError('no_contact')
    const g = b64(random(9)).replace(/\+/g, '-').replace(/\//g, '_')
    const chat = ensureChat(g, 'group', clean, ids)
    const body = { t: 'group', g, name: clean, members: [b64(me.card), ...ids.map((i) => state.contacts[i].card)] }
    await Promise.all(ids.map(async (i) => {
      try { await mesh.send(await buildPacket(state.contacts[i], body)) } catch { return }
    }))
    return chat
  }

  async function dropExpired() {
    for (const aid of Object.keys(pending)) if (pending[aid].ts < Date.now() - PENDING_TTL) await discard(aid)
  }

  async function discard(aid) {
    for (const k of await db.keysByPrefix('chunks', aid)) await db.del('chunks', k)
    delete pending[aid]
    await db.put('kv', 'pending', pending)
    await db.del('kv', `ptr/${aid}`)
  }

  const pendingBytes = () => Object.values(pending).reduce((n, x) => n + x.bytes, 0)

  async function onChunk(p) {
    let ch
    try { ch = parseChunk(p.payload) } catch { return }
    const { index, total, bytes } = ch
    const aid = hex(ch.attId)
    if (total < 1 || total > MAX_CHUNKS || index >= total || !bytes.length || bytes.length > CHUNK) return
    await dropExpired()
    const meta = pending[aid] || { ts: Date.now(), total, count: 0, bytes: 0 }
    const key = `${aid}/${index}`
    if (meta.total !== total || (await db.has('chunks', key)) || pendingBytes() + bytes.length > MAX_PENDING) return
    await db.putBin('chunks', key, bytes)
    meta.count++
    meta.bytes += bytes.length
    pending[aid] = meta
    await db.put('kv', 'pending', pending)
    if (meta.count === total) await tryFinish(aid)
  }

  async function tryFinish(aid) {
    const ptr = await db.get('kv', `ptr/${aid}`)
    const meta = pending[aid]
    if (!ptr || !meta || meta.count < meta.total) return
    const { f, msg, silent } = ptr
    try {
      if (meta.total !== msg.chunks) throw new Error('chunk count')
      const parts = []
      for (let i = 0; i < meta.total; i++) parts.push(await db.getBin('chunks', `${aid}/${i}`))
      const ct = concat(...parts)
      if (!equal(sha256(ct), unhex(msg.sha256))) throw new Error('hash')
      const plain = await decryptFile(ct, unb64(msg.key))
      if (plain.length !== msg.size) throw new Error('size')
      const mime = safeMime(msg.mime)
      await db.putBin('blobs', aid, plain)
      const att = { kind: msg.kind, mime, size: plain.length, attId: aid, url: URL.createObjectURL(new Blob([plain], { type: mime })) }
      if (Number.isFinite(msg.duration) && msg.duration > 0) att.duration = Math.min(msg.duration, 3600)
      if (typeof msg.wave === 'string' && msg.wave.length <= 96 && /^[A-Za-z0-9+/]*={0,2}$/.test(msg.wave)) att.wave = Array.from(unb64(msg.wave))
      const caption = captionOf(msg.text)
      const re = parseRe(msg.re)
      silentNow = !!silent
      await receive({ id: `${f}.${msg.id}`, chatId: msg.g || f, from: f, att, ...(caption && { text: caption }), ...(re && { re }) }, caption || '', `${t(msg.kind === 'image' ? 'notifPhoto' : 'notifAttachment')}${caption ? ': ' + caption : ''}`)
    } catch {
      silentNow = false
      return discard(aid)
    }
    silentNow = false
    await discard(aid)
  }

  const normName = (s) => String(s).normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim()
  const normId = (s) => String(s).toUpperCase().replace(/[^0-9A-Z]/g, '')
  const idLike = (s) => ID_RE.test(normId(s))
  const findHash = (norm) => b64url(sha256(utf8('ripplo-find-v1\0' + norm)).subarray(0, 8))
  const findKey = (text) => findHash(idLike(text) ? normId(text) : normName(text))
  const matchesQuery = (text, name, id) => (idLike(text) ? normId(id) === normId(text) : normName(name) === normName(text))

  function discoverRound({ payload, timeout, quiet }) {
    return new Promise((resolve) => {
      const id = newId()
      let quietTimer
      const finish = () => {
        clearTimeout(timer)
        clearTimeout(quietTimer)
        discover = null
        resolve()
      }
      const timer = setTimeout(finish, timeout)
      const d = {
        id: hex(id), finish, dead: false,
        bump() { if (d.dead) { clearTimeout(quietTimer); quietTimer = setTimeout(finish, quiet) } },
        settle() { d.dead = true; d.bump() },
      }
      discover = d
      mesh.send(encodePacket({ type: TYPE.DISCOVER, id, payload: utf8(JSON.stringify(payload)) }))
        .then((r) => { if (r && r.neighbors === 0) finish() })
        .catch(finish)
    })
  }

  async function refreshPeople() {
    if (state.peopleRefreshing) return
    state.peopleRefreshing = true
    state.peopleQuery = ''
    searchText = ''
    peopleBase = null
    state.people = []
    try {
      let lo = 0
      for (const h of RINGS) {
        const last = h === RINGS[RINGS.length - 1]
        await discoverRound({
          payload: { t: 'who', ...(!last && { h }), ...(lo && { lo }) },
          timeout: last ? T.discover : T.ring,
          quiet: last ? T.quiet : T.quietRing,
        })
        if (state.people.length >= MAX_SCAN) break
        lo = h
      }
    } finally {
      state.peopleRefreshing = false
      state.peopleRefreshedAt = Date.now()
      db.put('kv', 'peopleRefreshedAt', state.peopleRefreshedAt).catch(() => {})
    }
  }

  async function searchPeople(raw) {
    const text = String(raw ?? '').trim().slice(0, 40)
    if (state.peopleRefreshing) return
    if (!text) {
      if (peopleBase) { state.people = peopleBase; peopleBase = null }
      state.peopleQuery = ''
      searchText = ''
      return
    }
    if (!state.peopleQuery) peopleBase = state.people
    state.peopleQuery = searchText = text
    state.people = []
    state.peopleRefreshing = true
    try {
      await discoverRound({ payload: { t: 'who', q: findKey(text) }, timeout: T.discover, quiet: T.quiet })
    } finally {
      state.peopleRefreshing = false
    }
  }

  function onReply(p) {
    if (!discover || hex(p.dest) !== discover.id) return
    let v
    try { v = checkCard(p.payload) } catch { return }
    if (v.id === me.id) return
    if (searchText && !matchesQuery(searchText, v.name, v.id)) return
    markConflicts(v.name, v.id)
    const person = { id: v.id, name: v.name, card: b64(v.card), hops: p.hops, seenAt: Date.now(), isContact: !!state.contacts[v.id] }
    const limit = searchText ? MAX_SEARCH : MAX_SCAN
    const i = state.people.findIndex((x) => x.id === v.id)
    if (i >= 0) {
      if (person.hops < state.people[i].hops) state.people[i] = person
    } else if (state.people.length < limit) {
      state.people.push(person)
    } else {
      let far = 0
      for (let k = 1; k < state.people.length; k++) if (state.people[k].hops > state.people[far].hops) far = k
      if (person.hops < state.people[far].hops) state.people[far] = person
    }
    state.people.sort((a, b) => a.hops - b.hops)
    discover.bump()
  }

  function onDiscover(p) {
    if (state.settings.hidden) return
    if (discover && hex(p.id) === discover.id) return
    let q
    try { q = JSON.parse(unutf8(p.payload)) } catch { return }
    if (!q || q.t !== 'who') return
    const d = (p.hops || 0) + 1
    if (Number.isFinite(q.h) && d > q.h) return
    if (Number.isFinite(q.lo) && d <= q.lo) return
    if (q.q !== undefined && ![findHash(normName(me.name)), findHash(normId(me.id))].includes(q.q)) return
    mesh.send(encodePacket({ type: TYPE.REPLY, dest: p.id, payload: me.card })).catch(() => {})
  }

  async function deleteChat(chatId) {
    for (const m of await db.msgs(chatId)) {
      if (m.att) await db.del('blobs', m.att.attId)
      await db.delMsg(m.id)
    }
    delete state.messages[chatId]
    loaded.delete(chatId)
    state.chats = state.chats.filter((c) => c.id !== chatId)
    await db.del('chats', chatId)
  }

  async function deleteContact(id) {
    await deleteChat(id)
    const c = state.contacts[id]
    delete state.contacts[id]
    await db.del('contacts', id)
    if (c) await mesh.signalForget(hex(tagOf(c))).catch(() => {})
  }

  async function saveSettings(patch) {
    for (const k of ['autoUpdate', 'backgroundRelay', 'appLock', 'hidden', 'dev']) if (typeof patch[k] === 'boolean') state.settings[k] = patch[k]
    if (patch.hidden === false) for (const n of state.neighbors) sendHello(n.node, !n.card)
    if (patch.hidden === true) {
      for (const n of state.neighbors) {
        const c = n.card && state.contacts[n.card.id]
        if (!c || c.request) mesh.sendApp(n.node, utf8('{"t":"bye"}')).catch(() => {})
      }
    }
    await db.put('kv', 'settings', { ...state.settings })
  }

  return {
    state, init, close, createProfile, setAvatar, setName, searchPeople, unsendMessage, startCall: async (id) => { if (!canCall(state.contacts[id])) throw new RipploError('call_no_contact'); return calls.start(id) }, acceptCall: calls.accept, hangUp: calls.hangup, setMuted: calls.setMuted, myInviteLink: newInviteLink, addContactFromLink, invite, acceptRequest, declineRequest,
    verifyNearby, verifyByQr, markVerified, safetyNumber, sendTyping, sendText, sendAttachment, retry, loadMessages,
    markRead, createGroup, refreshPeople, deleteChat, deleteContact, saveSettings, restoreBackup, sendDevLog, deleteDevLog, nodeOf,
  }
}
