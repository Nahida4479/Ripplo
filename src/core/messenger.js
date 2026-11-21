import { SessionBuilder, SessionCipher, SignalProtocolAddress } from '@privacyresearch/libsignal-protocol-typescript'
import { PreKeyWhisperMessage } from '@privacyresearch/libsignal-protocol-protobuf-ts'
import { sha256 } from '@noble/hashes/sha2.js'
import { TYPE, newId, encodePacket, decodePacket } from '../mesh/packet.js'
import { b64, unb64, hex, unhex, utf8, unutf8, concat, random, ab, equal } from '../lib/bytes.js'
import { createVault } from '../crypto/vault.js'
import { openDb } from '../crypto/db.js'
import { createSignalStore } from '../crypto/signalStore.js'
import { RipploError, createIdentity, makeCard, checkCard, encodeLink, parseLink, deriveIds, cleanName } from '../crypto/identity.js'
import { seal, unseal } from '../crypto/sealed.js'
import { safetyNumber as computeSafety, proofMac, proofValid } from '../crypto/safety.js'
import { CHUNK, encryptFile, decryptFile, chunkCount, chunkPayload, parseChunk } from '../crypto/attachment.js'
import { createState } from './state.js'
import { notify } from '../services/notifications.js'

export const MAX_TEXT = 1000
export const MAX_FILE = 20 * 1024 * 1024

const MAX_PENDING = 100 * 1024 * 1024
const PENDING_TTL = 24 * 3600 * 1000
const MAX_CHUNKS = 700
const MAX_GROUP = 30
const WINDOW = 4
const ID_RE = /^[0-9A-HJKMNP-TV-Z]{16}$/
const WIRE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/
const KINDS = ['image', 'video', 'voice']
const DEFAULT_TIMING = { ack: 300000, discover: 30000, verify: 60000, proof: 5000, poll: 500 }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const latin1 = (bytes) => Array.from(bytes, (b) => String.fromCharCode(b)).join('')
const pktId = (pkt) => hex(pkt.subarray(4, 20))
const safeMime = (m) => {
  const base = String(m || '').split(';')[0].trim().toLowerCase()
  return /^(image|video|audio)\/[a-z0-9.+-]{1,40}$/.test(base) ? base : 'application/octet-stream'
}

export function createCore({ mesh, dbName = 'ripplo', state = createState(), notifier = notify, timing = {} }) {
  const T = { ...DEFAULT_TIMING, ...timing }
  let db = null
  let store = null
  let me = null
  let unsubs = []
  let queue = Promise.resolve()
  let pending = {}
  let discover = null
  const loaded = new Set()
  const waits = new Map()
  const proofs = new Map()
  const running = new Map()
  const seenIds = new Set()

  const enqueue = (fn) => { queue = queue.then(fn).catch(() => {}) }

  const persistContact = (c) => db.put('contacts', c.id, { ...c })
  const persistChat = (c) => db.put('chats', c.id, { ...c })
  const persistMsg = (m) => db.putMsg({ ...m, att: m.att && { ...m.att, url: undefined } })
  const tagOf = (c) => deriveIds(unb64(c.ik)).tag

  function loadMe(local) {
    const ik = { pub: unb64(local.ik.pub), priv: unb64(local.ik.priv) }
    const { tag, ripploId } = deriveIds(ik.pub)
    const identity = { ik, regId: local.regId, spk: { id: local.spk.id, pub: unb64(local.spk.pub), sig: unb64(local.spk.sig) } }
    me = { ik, tag, id: ripploId, name: local.name, card: makeCard(identity, local.name) }
    state.profile = { name: local.name, ripploId, tag: hex(tag) }
  }

  async function init() {
    const vault = await createVault(mesh)
    state.insecureStorage = vault.insecure
    db = await openDb(dbName, vault)
    store = createSignalStore(db)
    Object.assign(state.settings, (await db.get('kv', 'settings')) || {})
    state.contacts = Object.fromEntries((await db.all('contacts')).map(([id, c]) => [id, { ...c, verifyState: 'idle' }]))
    state.chats = (await db.all('chats')).map(([, c]) => c).sort((a, b) => b.lastTs - a.lastTs)
    pending = (await db.get('kv', 'pending')) || {}
    const local = await store.local()
    state.needsOnboarding = !local
    if (local) {
      loadMe(local)
      await dropExpired()
      await start()
    }
    state.ready = true
  }

  async function createProfile(name) {
    const clean = cleanName(name)
    if (!clean) throw new RipploError('bad_name')
    const identity = await createIdentity()
    await store.setLocal({ ...identity, name: clean })
    loadMe(await store.local())
    state.needsOnboarding = false
    await start()
  }

  async function start() {
    unsubs.push(mesh.on('packet', ({ packet, from }) => onPacket(packet, from)))
    unsubs.push(mesh.on('neighbor', onNeighbor))
    await mesh.start(me.tag)
    for (const n of (await mesh.getNeighbors()) || []) onNeighbor({ ...n, up: true })
    for (const { packet, from } of (await mesh.drainInbox()) || []) onPacket(packet, from)
  }

  function close() {
    unsubs.forEach((u) => u && u())
    unsubs = []
    waits.forEach((w) => clearTimeout(w.timer))
    waits.clear()
    return db && db.close()
  }

  function onNeighbor({ node, up, medium, kbps, rttMs }) {
    const i = state.neighbors.findIndex((n) => n.node === node)
    if (!up) {
      if (i >= 0) state.neighbors.splice(i, 1)
      return
    }
    if (i >= 0) Object.assign(state.neighbors[i], { medium, kbps, rttMs })
    else state.neighbors.push({ node, medium, kbps, rttMs })
    mesh.sendApp(node, utf8(JSON.stringify({ t: 'hello', card: me.card }))).catch(() => {})
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
        enqueue(() => (p.payload[0] === 2 ? onChunk(p) : onSealed(p.payload)))
        break
      case TYPE.ACK: settle(hex(p.dest), { ok: true, hops: p.hops }); break
      case TYPE.DEAD_END:
        if (discover && hex(p.dest) === discover.id) discover.finish()
        else settle(hex(p.dest), { ok: false })
        break
      case TYPE.DISCOVER: onDiscover(p); break
      case TYPE.REPLY: onReply(p); break
      case TYPE.APP: onApp(p, from).catch(() => {}); break
    }
  }

  function transmit(pkt) {
    const id = pktId(pkt)
    return new Promise((resolve) => {
      const timer = setTimeout(() => settle(id, { ok: false }), T.ack)
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

  async function createSession(card, id) {
    try {
      await new SessionBuilder(store, new SignalProtocolAddress(id, 1)).processPreKey({
        identityKey: ab(unb64(card.ik)),
        registrationId: card.rid,
        signedPreKey: { keyId: card.spk.id, publicKey: ab(unb64(card.spk.pub)), signature: ab(unb64(card.spk.sig)) },
      })
    } catch {
      throw new RipploError('bad_link', 'invalid prekey bundle')
    }
  }

  async function ensureSession(c) {
    if (await store.loadSession(new SignalProtocolAddress(c.id, 1).toString())) return
    if (!c.card) throw new RipploError('no_session')
    await createSession(c.card, c.id)
  }

  async function buildPacket(c, obj) {
    await ensureSession(c)
    const cipher = new SessionCipher(store, new SignalProtocolAddress(c.id, 1))
    const { type, body } = await cipher.encrypt(ab(utf8(JSON.stringify(obj))))
    const inner = utf8(JSON.stringify({ f: me.id, t: type, b: b64(Uint8Array.from(body, (ch) => ch.charCodeAt(0))) }))
    const sealed = await seal(unb64(c.ik), tagOf(c), inner)
    return encodePacket({ type: TYPE.DATA, dest: tagOf(c), payload: sealed })
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

  const textBody = (m, group) => ({ t: 'msg', id: m.id, text: m.text, ts: m.ts, ...(group && { g: group }) })
  const groupOf = (chatId) => (state.chats.find((c) => c.id === chatId)?.type === 'group' ? chatId : undefined)

  async function sendText(chatId, text) {
    if (typeof text !== 'string' || !text.trim()) throw new RipploError('empty')
    if (text.length > MAX_TEXT) throw new RipploError('too_long')
    const { m, recips } = newOutgoing(chatId, { text })
    touchChat(chatId, text, m.ts)
    fanout(m, textBody(m, groupOf(chatId)), recips).catch(() => {})
    return m
  }

  async function sendAttachment(chatId, file, kind) {
    if (!KINDS.includes(kind)) throw new RipploError('bad_kind')
    if (file.size > MAX_FILE) throw new RipploError('too_big')
    const bytes = new Uint8Array(await file.arrayBuffer())
    const attId = hex(random(16))
    await db.putBin('blobs', attId, bytes)
    const att = { kind, mime: safeMime(file.type), size: bytes.length, attId, url: URL.createObjectURL(file) }
    if (file.duration) att.duration = file.duration
    const { m, recips } = newOutgoing(chatId, { att, progress: 0 })
    touchChat(chatId, '', m.ts, 0, kind)
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
      const worker = async () => {
        while (!failed && next < total) {
          const i = next++
          const r = await transmit(encodePacket({ type: TYPE.DATA, dest, payload: chunkPayload(attId, ct, i, total) }))
          if (!r.ok) { failed = true; return }
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
      sha256: hex(hash), key: b64(key), chunks: total, ts: m.ts, ...(g && { g }), ...(m.att.duration && { duration: m.att.duration }),
    }
    await fanout(m, body, okRecips)
  }

  async function retry(msgId) {
    const m = Object.values(state.messages).flat().find((x) => x.id === msgId)
    if (!m || m.from !== 'me' || !['out_of_range', 'failed'].includes(m.status)) return
    const recips = m.undelivered.length ? [...m.undelivered] : recipientsOf(m.chatId)
    m.errored = false
    if (m.text !== undefined) fanout(m, textBody(m, groupOf(m.chatId)), recips).catch(() => {})
    else runAttachment(m, await db.getBin('blobs', m.att.attId), recips).catch(() => { m.status = 'failed'; persistMsg(m) })
  }

  async function onSealed(payload) {
    const inner = JSON.parse(unutf8(await unseal(me.ik.priv, me.tag, payload)))
    const { f, t, b } = inner
    if (!ID_RE.test(f) || f === me.id || (t !== 1 && t !== 3) || typeof b !== 'string') return
    const body = latin1(unb64(b))
    let idKey = null
    if (t === 3) {
      idKey = new Uint8Array(PreKeyWhisperMessage.decode(Uint8Array.from(body.slice(1), (ch) => ch.charCodeAt(0))).identityKey)
      if (idKey.length !== 33 || idKey[0] !== 5 || deriveIds(idKey).ripploId !== f) return
    }
    const cipher = new SessionCipher(store, new SignalProtocolAddress(f, 1))
    const plain = t === 3 ? await cipher.decryptPreKeyWhisperMessage(body, 'binary') : await cipher.decryptWhisperMessage(body, 'binary')
    const used = await store.loadIdentity(f)
    if (!used || deriveIds(used).ripploId !== f) return
    if (!state.contacts[f]) await addContact({ id: f, name: knownName(f) || `Ripplo ${f.slice(0, 4)}`, ik: b64(used), card: null, addedVia: 'incoming' })
    await onAppMessage(f, JSON.parse(unutf8(new Uint8Array(plain))))
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
      await receive({ id: `${f}.${msg.id}`, chatId, from: f, text: msg.text }, msg.text)
    } else if (msg.t === 'att') {
      if (!WIRE_ID_RE.test(msg.id) || !/^[0-9a-f]{32}$/.test(msg.attId) || !KINDS.includes(msg.kind) || !/^[0-9a-f]{64}$/.test(msg.sha256)) return
      if (!Number.isInteger(msg.size) || msg.size < 0 || msg.size > MAX_FILE || !Number.isInteger(msg.chunks) || msg.chunks < 1 || msg.chunks > MAX_CHUNKS) return
      if (typeof msg.key !== 'string' || unb64(msg.key).length !== 32 || !routeChat(f, msg.g)) return
      await db.put('kv', `ptr/${msg.attId}`, { f, msg })
      await tryFinish(msg.attId)
    } else if (msg.t === 'group') {
      await onGroup(f, msg)
    }
  }

  async function receive(m, preview, notifyBody = preview) {
    if (await db.hasMsg(m.id)) return
    const msg = addMsg({ ...m, ts: Date.now(), status: 'received' })
    touchChat(m.chatId, preview, msg.ts, 1, m.att?.kind)
    const chat = state.chats.find((c) => c.id === m.chatId)
    notifier({ title: chat?.type === 'group' ? `${chat.name}: ${state.contacts[m.from]?.name}` : state.contacts[m.from]?.name, body: notifyBody, chatId: m.chatId })
  }

  async function onGroup(f, msg) {
    if (!/^[A-Za-z0-9_-]{6,32}$/.test(msg.g) || !Array.isArray(msg.members) || msg.members.length < 2 || msg.members.length > MAX_GROUP + 1) return
    const name = cleanName(msg.name)
    if (!name) return
    let cards
    try { cards = msg.members.map(checkCard) } catch { return }
    const ids = cards.map((c) => c.id)
    if (!ids.includes(f) || !ids.includes(me.id)) return
    const existing = state.chats.find((c) => c.id === msg.g)
    if (existing && (existing.type !== 'group' || !existing.members.includes(f))) return
    for (const v of cards) if (v.id !== me.id) await learnCard(v, 'group')
    ensureChat(msg.g, 'group', name, ids.filter((i) => i !== me.id))
  }

  async function addContact({ id, name, ik, card, addedVia }) {
    state.contacts[id] = {
      id, name, ik, card, verification: 'none', verifiedAt: 0, verifyState: 'idle',
      addedVia, addedAt: Date.now(), conflict: false,
    }
    const c = state.contacts[id]
    markConflicts(name, id)
    ensureChat(id, 'direct', name)
    await persistContact(c)
    return c
  }

  async function learnCard(v, via) {
    const c = state.contacts[v.id]
    if (!c) {
      const created = await addContact({ id: v.id, name: v.card.n, ik: v.card.ik, card: v.card, addedVia: via })
      return created
    }
    if (!c.card && c.ik === v.card.ik) {
      c.card = v.card
      c.name = v.card.n
      ensureChat(c.id, 'direct', c.name)
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

  async function addCard(raw, via) {
    const v = checkCard(raw)
    if (v.id === me.id) throw new RipploError('self')
    const existing = state.contacts[v.id]
    if (existing) return learnCard(v, via)
    await createSession(v.card, v.id)
    const c = await learnCard(v, via)
    const person = state.people.find((p) => p.id === v.id)
    if (person) person.isContact = true
    if (['link', 'qr', 'people'].includes(via)) verifyNearby(v.id).catch(() => {})
    return c
  }

  async function addContactFromLink(text, via = 'link') {
    const v = parseLink(text)
    if (v.id === me.id) throw new RipploError('self')
    return addCard(v.card, via)
  }

  const addPerson = (person) => addCard(person.card, 'people')

  async function onApp(p, from) {
    const msg = JSON.parse(unutf8(p.payload))
    const nb = state.neighbors.find((n) => n.node === from)
    if (!nb || !msg || typeof msg !== 'object') return
    if (msg.t === 'hello') {
      const v = checkCard(msg.card)
      if (v.id === me.id) return
      nb.card = { id: v.id, name: v.card.n, ik: v.card.ik, card: v.card }
      markConflicts(v.card.n, v.id)
      if (state.contacts[v.id]) await learnCard(v, 'link')
    } else if (msg.t === 'challenge') {
      const n = unb64(msg.n)
      const ik = nb.card && nb.card.id === msg.from ? unb64(nb.card.ik) : state.contacts[msg.from] && unb64(state.contacts[msg.from].ik)
      if (n.length !== 32 || !ik || deriveIds(ik).ripploId !== msg.from) return
      const mac = proofMac(me.ik.priv, ik, n, deriveIds(ik).tag, me.tag)
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
    return proofValid(mac, proofMac(me.ik.priv, ik, n, me.tag, deriveIds(ik).tag)) ? 'ok' : 'bad'
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
      return ok
    })().finally(() => running.delete(id))
    running.set(id, job)
    return job
  }

  async function setVerified(id, level) {
    const c = state.contacts[id]
    if (!c) return false
    Object.assign(c, { verification: level, verifiedAt: Date.now(), verifyState: 'idle' })
    await persistContact(c)
    return true
  }

  async function verifyByQr(id, scanned) {
    const c = state.contacts[id]
    if (!c) return false
    const text = String(scanned)
    const digits = text.replace(/\s+/g, '')
    if (/^\d{60}$/.test(digits)) return digits === safetyNumber(id) && setVerified(id, 'qr')
    try {
      const v = parseLink(text)
      return v.card.ik === c.ik && (await setVerified(id, 'qr'))
    } catch {
      return false
    }
  }

  const markVerified = (id) => setVerified(id, 'manual').then(() => {})

  function safetyNumber(id) {
    const c = state.contacts[id]
    if (!c) throw new RipploError('no_contact')
    return computeSafety(me.ik.pub, me.id, unb64(c.ik), id)
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
    if (ids.some((i) => !state.contacts[i] || !state.contacts[i].card)) throw new RipploError('no_contact')
    const g = b64(random(9)).replace(/\+/g, '-').replace(/\//g, '_')
    const chat = ensureChat(g, 'group', clean, ids)
    const body = { t: 'group', g, name: clean, members: [me.card, ...ids.map((i) => state.contacts[i].card)] }
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
    const { f, msg } = ptr
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
      if (Number.isFinite(msg.duration)) att.duration = msg.duration
      await receive({ id: `${f}.${msg.id}`, chatId: msg.g || f, from: f, att }, '', msg.kind)
    } catch {
      return discard(aid)
    }
    await discard(aid)
  }

  async function refreshPeople() {
    if (discover) return
    state.peopleRefreshing = true
    state.people = []
    const id = newId()
    await new Promise((resolve) => {
      const finish = () => {
        clearTimeout(timer)
        discover = null
        state.peopleRefreshing = false
        state.peopleRefreshedAt = Date.now()
        resolve()
      }
      const timer = setTimeout(finish, T.discover)
      discover = { id: hex(id), finish }
      mesh.send(encodePacket({ type: TYPE.DISCOVER, id, payload: utf8('{"t":"who"}') })).catch(finish)
    })
  }

  function onReply(p) {
    if (!discover || hex(p.dest) !== discover.id) return
    let v
    try { v = checkCard(JSON.parse(unutf8(p.payload))) } catch { return }
    if (v.id === me.id) return
    markConflicts(v.card.n, v.id)
    const person = { id: v.id, name: v.card.n, card: v.card, hops: p.hops, seenAt: Date.now(), isContact: !!state.contacts[v.id] }
    const i = state.people.findIndex((x) => x.id === v.id)
    if (i < 0) state.people.push(person)
    else if (person.hops < state.people[i].hops) state.people[i] = person
  }

  function onDiscover(p) {
    if (discover && hex(p.id) === discover.id) return
    try { if (JSON.parse(unutf8(p.payload)).t !== 'who') return } catch { return }
    mesh.send(encodePacket({ type: TYPE.REPLY, dest: p.id, payload: utf8(JSON.stringify(me.card)) })).catch(() => {})
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
    delete state.contacts[id]
    await db.del('contacts', id)
    await store.removeSession(new SignalProtocolAddress(id, 1).toString())
  }

  async function saveSettings(patch) {
    for (const k of ['autoUpdate', 'backgroundRelay']) if (typeof patch[k] === 'boolean') state.settings[k] = patch[k]
    await db.put('kv', 'settings', { ...state.settings })
  }

  return {
    state, init, close, createProfile, myInviteLink: () => encodeLink(me.card), addContactFromLink, addPerson,
    verifyNearby, verifyByQr, markVerified, safetyNumber, sendText, sendAttachment, retry, loadMessages,
    markRead, createGroup, refreshPeople, deleteChat, deleteContact, saveSettings,
  }
}
