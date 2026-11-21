import 'fake-indexeddb/auto'
import { describe, it, expect } from 'vitest'
import { resolveObjectURL } from 'node:buffer'
import { createCore } from '../src/core/messenger.js'
import { TYPE, encodePacket, decodePacket, newId } from '../src/mesh/packet.js'
import { createDevSignal } from '../src/mesh/devSignal.js'
import { parseLink } from '../src/crypto/identity.js'
import { isAvatar } from '../src/lib/avatar.js'
import { createVault } from '../src/crypto/vault.js'
import { openDb } from '../src/crypto/db.js'
import { b64, b64url, hex, utf8, unutf8, random, concat } from '../src/lib/bytes.js'
import { sha256 } from '@noble/hashes/sha2.js'

const nodes = []
function fakeMesh() {
  const handlers = { packet: [], neighbor: [] }
  const m = {
    ...createDevSignal(), devCrypto: true, isNative: false, node: hex(random(8)), tag: '', neighbors: new Set(), offline: false,
    on(ev, cb) { handlers[ev].push(cb); return () => handlers[ev].splice(handlers[ev].indexOf(cb), 1) },
    emit(ev, d) { setTimeout(() => handlers[ev].slice().forEach((h) => h(d)), 0) },
    async start(tag) { m.tag = hex(tag); return { nodeTag: m.node } },
    async getNeighbors() { return [] },
    async drainInbox() { return [] },
    async getDbKey() { return { key: random(32), insecure: false } },
    async sendApp(node, payload) {
      const t = nodes.find((n) => n.node === node)
      if (t && m.neighbors.has(node)) t.emit('packet', { packet: encodePacket({ type: TYPE.APP, payload }), from: m.node })
    },
    async send(pkt) {
      const p = decodePacket(pkt)
      const others = nodes.filter((n) => n !== m && !n.offline && !m.offline)
      if (p.type === TYPE.DATA) {
        const t = others.find((n) => n.tag === hex(p.dest))
        if (!t) return m.emit('packet', { packet: encodePacket({ type: TYPE.DEAD_END, dest: p.id }), from: 'self' })
        t.emit('packet', { packet: pkt, from: m.node })
        m.emit('packet', { packet: encodePacket({ type: TYPE.ACK, dest: p.id, hops: 1 }), from: 'self' })
      } else if (p.type === TYPE.DISCOVER) {
        others.forEach((n) => { n.origin = n.origin || {}; n.origin[hex(p.id)] = m; n.emit('packet', { packet: pkt, from: m.node }) })
        setTimeout(() => m.emit('packet', { packet: encodePacket({ type: TYPE.DEAD_END, dest: p.id }), from: 'self' }), 100)
      } else if (p.type === TYPE.REPLY) {
        m.origin[hex(p.dest)].emit('packet', { packet: encodePacket({ type: TYPE.REPLY, dest: p.dest, hops: 1, payload: p.payload }), from: 'self' })
      }
      return { neighbors: others.length }
    },
  }
  nodes.push(m)
  return m
}
const connect = (a, b) => {
  a.neighbors.add(b.node); b.neighbors.add(a.node)
  a.emit('neighbor', { node: b.node, up: true, medium: 'lan', kbps: 1000 })
  b.emit('neighbor', { node: a.node, up: true, medium: 'lan', kbps: 1000 })
}
const waitFor = async (fn, ms = 4000) => {
  const end = Date.now() + ms
  for (;;) {
    const v = fn()
    if (v) return v
    if (Date.now() > end) throw new Error('timeout: ' + fn)
    await new Promise((r) => setTimeout(r, 10))
  }
}
const TIMING = { ack: 1500, verify: 1200, proof: 300, poll: 30, discover: 600 }

async function user(name) {
  const mesh = fakeMesh()
  const core = createCore({ mesh, dbName: `db-${name}-${hex(random(4))}`, notifier: () => {}, timing: TIMING })
  await core.init()
  await core.createProfile(name)
  return { mesh, core, state: core.state, id: core.state.profile.ripploId, link: core.myInviteLink() }
}
const codeOf = async (p) => { try { await p; return null } catch (e) { return e.code } }

describe('messaging', () => {
  it('Alice -> Bob (PreKey), Bob -> Alice, several messages', async () => {
    const a = await user('Alice'), b = await user('Bob')
    const contact = await a.core.addContactFromLink(b.link)
    expect(contact.id).toBe(b.id)
    expect(contact.verification).toBe('none')
    const m1 = await a.core.sendText(b.id, 'hello bob')
    await waitFor(() => m1.status === 'delivered')
    expect(m1.hops).toBe(1)
    const inc = await waitFor(() => b.state.messages[a.id]?.[0])
    expect(inc.text).toBe('hello bob')
    expect(b.state.contacts[a.id]).toMatchObject({ addedVia: 'incoming', verification: 'none' })
    expect(b.state.chats.find((c) => c.id === a.id).unread).toBe(1)
    const r1 = await b.core.sendText(a.id, 'hi alice')
    await waitFor(() => r1.status === 'delivered')
    await waitFor(() => a.state.messages[b.id]?.some((m) => m.text === 'hi alice'))
    for (let i = 0; i < 5; i++) {
      await a.core.sendText(b.id, `a${i}`)
      await b.core.sendText(a.id, `b${i}`)
    }
    await waitFor(() => b.state.messages[a.id].length === 12 && a.state.messages[b.id].length === 12)
    expect(b.state.messages[a.id].map((m) => m.text).filter((t) => t.startsWith('a')).sort()).toEqual(['a0', 'a1', 'a2', 'a3', 'a4'])
    b.core.markRead(a.id)
    expect(b.state.chats.find((c) => c.id === a.id).unread).toBe(0)
  })

  it('rejects text over 1000 chars, own link and a card with a bad bundle', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    expect(await codeOf(a.core.sendText(b.id, 'x'.repeat(1001)))).toBe('too_long')
    expect(await codeOf(a.core.addContactFromLink(a.link))).toBe('self')
    const card = parseLink(b.link).card.slice()
    card[2 + card[1] + 5] = 4
    const forged = `ripplo://add/${b64url(card)}.${b64url(sha256(card).slice(0, 6))}`
    const c = await user('Carol')
    expect(await codeOf(c.core.addContactFromLink(forged))).toBe('bad_link')
    expect(c.state.contacts[b.id]).toBeUndefined()
  })

  it('drops a malformed sealed payload without creating a contact', async () => {
    const b = await user('Bob')
    const { tag } = parseLink(b.link)
    b.mesh.emit('packet', { packet: encodePacket({ type: TYPE.DATA, dest: tag, payload: concat(new Uint8Array([0xee, 5]), random(10)) }), from: 'x' })
    await new Promise((r) => setTimeout(r, 200))
    expect(Object.keys(b.state.contacts)).toEqual([])
  })

  it('retries after out_of_range', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    b.mesh.offline = true
    const m = await a.core.sendText(b.id, 'later')
    await waitFor(() => m.status === 'out_of_range')
    b.mesh.offline = false
    await a.core.retry(m.id)
    await waitFor(() => m.status === 'delivered')
    await waitFor(() => b.state.messages[a.id]?.length === 1)
  })
})

describe('verification', () => {
  it('nearby proof succeeds for the real key holder', async () => {
    const a = await user('Alice'), b = await user('Bob')
    connect(a.mesh, b.mesh)
    await waitFor(() => a.state.neighbors[0]?.card && b.state.neighbors[0]?.card)
    const c = await a.core.addContactFromLink(b.link, 'link')
    await waitFor(() => c.verification === 'nearby')
    const q = await user('Qia'), r = await user('Rob')
    connect(q.mesh, r.mesh)
    await waitFor(() => q.state.neighbors[0]?.card)
    const rc = await q.core.addContactFromLink(r.link, 'qr')
    await waitFor(() => rc.verification === 'qr')
  })

  it('proof fails for a node announcing the card without the private key; same name other key flags conflict', async () => {
    const a = await user('Alice'), b = await user('Bob')
    const c = await a.core.addContactFromLink(b.link)
    const mal = fakeMesh()
    mal.on('packet', ({ packet }) => {
      const p = decodePacket(packet)
      const msg = JSON.parse(unutf8(p.payload))
      if (msg.t === 'challenge') mal.sendApp(a.mesh.node, utf8(JSON.stringify({ t: 'proof', n: msg.n, mac: b64(random(32)) })))
    })
    connect(a.mesh, mal)
    await waitFor(() => a.state.neighbors.length === 1)
    mal.sendApp(a.mesh.node, utf8(JSON.stringify({ t: 'hello', card: b64(parseLink(b.link).card) })))
    expect(await a.core.verifyNearby(b.id)).toBe(false)
    expect(c.verifyState).toBe('failed')
    expect(c.verification).toBe('none')
    const evil = await user('Bob')
    mal.sendApp(a.mesh.node, utf8(JSON.stringify({ t: 'hello', card: b64(parseLink(evil.link).card) })))
    await waitFor(() => c.conflict)
  })

  it('verifyByQr accepts the safety number or the matching link and markVerified sets manual', async () => {
    const a = await user('Alice'), b = await user('Bob'), x = await user('Xavier')
    await a.core.addContactFromLink(b.link)
    await b.core.addContactFromLink(a.link)
    const sn = await a.core.safetyNumber(b.id)
    expect(sn).toMatch(/^\d{60}$/)
    expect(await b.core.safetyNumber(a.id)).toBe(sn)
    expect(await a.core.verifyByQr(b.id, x.link)).toBe(false)
    expect(await a.core.verifyByQr(b.id, '1'.repeat(60))).toBe(false)
    expect(await a.core.verifyByQr(b.id, 'garbage')).toBe(false)
    expect(await a.core.verifyByQr(b.id, sn.replace(/(.{5})/g, '$1 '))).toBe(true)
    expect(a.state.contacts[b.id].verification).toBe('qr')
    expect(await b.core.verifyByQr(a.id, a.link)).toBe(true)
    await a.core.addContactFromLink(x.link)
    await a.core.markVerified(x.id)
    expect(a.state.contacts[x.id].verification).toBe('manual')
  })
})

describe('attachments, groups, people', () => {
  it('sends a 100 KB file through chunks', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    const data = random(100 * 1024)
    const m = await a.core.sendAttachment(b.id, new Blob([data], { type: 'image/png' }), 'image')
    await waitFor(() => m.status === 'delivered', 8000)
    expect(m.progress).toBe(1)
    const got = await waitFor(() => b.state.messages[a.id]?.[0], 8000)
    expect(got.att).toMatchObject({ kind: 'image', mime: 'image/png', size: data.length })
    const blob = resolveObjectURL(got.att.url)
    expect(new Uint8Array(await blob.arrayBuffer())).toEqual(data)
  })

  it('rejects files over 20 MiB', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    expect(await codeOf(a.core.sendAttachment(b.id, { size: 21 * 1024 * 1024, type: 'video/mp4' }, 'video'))).toBe('too_big')
  })

  it('group fan-out tracks delivered/total', async () => {
    const a = await user('Alice'), b = await user('Bob'), c = await user('Carol')
    await a.core.addContactFromLink(b.link)
    await a.core.addContactFromLink(c.link)
    const chat = await a.core.createGroup('Trio', [b.id, c.id])
    await waitFor(() => b.state.chats.some((x) => x.id === chat.id) && c.state.chats.some((x) => x.id === chat.id))
    const m = await a.core.sendText(chat.id, 'all')
    await waitFor(() => m.status === 'delivered')
    expect([m.delivered, m.total]).toEqual([2, 2])
    await waitFor(() => b.state.messages[chat.id]?.[0]?.text === 'all' && c.state.messages[chat.id]?.[0]?.text === 'all')
    const reply = await b.core.sendText(chat.id, 'from bob')
    await waitFor(() => reply.status === 'delivered')
    await waitFor(() => c.state.messages[chat.id].length === 2 && a.state.messages[chat.id].length === 2)
  })

  it('refreshPeople finds others and not itself', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.refreshPeople()
    
    expect(a.state.people.some((p) => p.id === a.id)).toBe(false)
    expect(a.state.people.find((p) => p.id === b.id)).toMatchObject({ name: 'Bob', hops: 1, isContact: false })
    expect(a.state.peopleRefreshing).toBe(false)
  })

  it('persists settings', async () => {
    const a = await user('Alice')
    await a.core.saveSettings({ autoUpdate: false })
    expect(a.state.settings).toEqual({ autoUpdate: false, backgroundRelay: true })
  })
})

describe('card piggyback and session reset', () => {
  it('sends the card until the contact answers, and the receiver stores it', async () => {
    const a = await user('Alice'), b = await user('Bob')
    const seen = []
    const seal = a.mesh.signalSeal
    a.mesh.signalSeal = (tag, pt) => { seen.push(JSON.parse(unutf8(pt))); return seal(tag, pt) }
    await a.core.addContactFromLink(b.link)
    await a.core.sendText(b.id, 'one')
    await waitFor(() => b.state.contacts[a.id]?.card)
    expect(b.state.contacts[a.id].name).toBe('Alice')
    expect(seen[0].c).toBeTruthy()
    await b.core.sendText(a.id, 'reply')
    await waitFor(() => a.state.contacts[b.id].cardAck)
    await a.core.sendText(b.id, 'two')
    await waitFor(() => seen.length >= 2)
    expect(seen.at(-1).c).toBeUndefined()
  })

  it('rejects a piggybacked card for another identity', async () => {
    const a = await user('Alice'), b = await user('Bob'), c = await user('Carol')
    await b.core.addContactFromLink(a.link)
    const forged = b.state.contacts[a.id]
    const seal = a.mesh.signalSeal
    a.mesh.signalSeal = (tag, pt) => seal(tag, utf8(JSON.stringify({ ...JSON.parse(unutf8(pt)), c: b64(parseLink(c.link).card) })))
    await a.core.addContactFromLink(b.link)
    await a.core.sendText(b.id, 'hi')
    await waitFor(() => b.state.messages[a.id]?.length)
    expect(forged.card).not.toBe(b64(parseLink(c.link).card))
  })

  it('resets the session on a decrypt failure once per 10 minutes and tells the user', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    await a.core.sendText(b.id, 'one')
    await waitFor(() => b.state.contacts[a.id]?.card)
    const calls = []
    const forget = b.mesh.signalForget
    b.mesh.signalForget = (tag) => { calls.push(tag); return forget(tag) }
    const open = b.mesh.signalOpen
    b.mesh.signalOpen = async () => { throw Object.assign(new Error('x'), { code: 'bad_message', data: { tag: hex(parseLink(a.link).tag) } }) }
    await a.core.sendText(b.id, 'two')
    await waitFor(() => b.state.messages[a.id]?.some((m) => m.from === 'system'))
    expect(b.state.messages[a.id].find((m) => m.from === 'system').text).toContain('Alice')
    expect(calls).toEqual([hex(parseLink(a.link).tag)])
    await a.core.sendText(b.id, 'three')
    await new Promise((r) => setTimeout(r, 200))
    expect(b.state.messages[a.id].filter((m) => m.from === 'system')).toHaveLength(1)
    b.mesh.signalOpen = open
    await a.core.sendText(b.id, 'four')
    await waitFor(() => b.state.messages[a.id].some((m) => m.text === 'four'))
  })

  it('resets every contact with a card after a restore', async () => {
    const a = await user('Alice'), b = await user('Bob')
    const mesh = fakeMesh()
    const key = random(32)
    mesh.getDbKey = async () => ({ key, insecure: false })
    mesh.backupRestore = async () => ({ meta: {} })
    const calls = []
    const forget = mesh.signalForget
    mesh.signalForget = (tag) => { calls.push(tag); return forget(tag) }
    const dbName = `db-restore-${hex(random(4))}`
    const first = createCore({ mesh, dbName, notifier: () => {}, timing: TIMING })
    await first.init()
    await first.createProfile('Carol')
    await first.addContactFromLink(a.link)
    await first.addContactFromLink(b.link)
    await first.restoreBackup('1'.repeat(30))
    await first.close()
    const second = createCore({ mesh, dbName, notifier: () => {}, timing: TIMING })
    await second.init()
    expect(calls.sort()).toEqual([hex(parseLink(a.link).tag), hex(parseLink(b.link).tag)].sort())
    expect(await (await openDb(dbName, await createVault(mesh), mesh)).get('kv', 'needsSessionReset')).toBeUndefined()
  })
})

describe('profile picture', () => {
  const jpeg = (n) => b64(concat(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]), new Uint8Array(n).fill(7)))
  it('validates avatars', () => {
    expect(isAvatar(jpeg(100))).toBe(true)
    expect(isAvatar(b64(utf8('<svg onload=alert(1)>')))).toBe(false)
    expect(isAvatar(jpeg(20000))).toBe(false)
    expect(isAvatar('')).toBe(false)
  })

  it('reaches the contact with the first message and follows changes and removal', async () => {
    const a = await user('Alice'), b = await user('Bob')
    expect(await codeOf(a.core.setAvatar('not-a-jpeg'))).toBe('bad_avatar')
    await a.core.setAvatar(jpeg(100))
    await a.core.addContactFromLink(b.link)
    await a.core.sendText(b.id, 'hi')
    await waitFor(() => b.state.contacts[a.id]?.avatar === jpeg(100))
    await a.core.setAvatar(jpeg(200))
    await waitFor(() => b.state.contacts[a.id].avatar === jpeg(200))
    await a.core.setAvatar('')
    await waitFor(() => b.state.contacts[a.id].avatar === '')
    expect(a.state.profile.avatar).toBe('')
  })

  it('ignores an invalid avatar from a peer', async () => {
    const a = await user('Alice'), b = await user('Bob')
    const seal = a.mesh.signalSeal
    a.mesh.signalSeal = (tag, pt) => seal(tag, utf8(JSON.stringify({ ...JSON.parse(unutf8(pt)), av: b64(utf8('<svg/>')) })))
    await a.core.addContactFromLink(b.link)
    await a.core.sendText(b.id, 'hi')
    await waitFor(() => b.state.contacts[a.id])
    await waitFor(() => b.state.messages[a.id]?.length)
    expect(b.state.contacts[a.id].avatar).toBeUndefined()
  })
})
