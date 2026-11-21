import 'fake-indexeddb/auto'
import { describe, it, expect, beforeEach } from 'vitest'
import { resolveObjectURL } from 'node:buffer'
import { createCore } from '../src/core/messenger.js'
import { TYPE, encodePacket, decodePacket, newId } from '../src/mesh/packet.js'
import { createDevSignal } from '../src/mesh/devSignal.js'
import { parseLink } from '../src/crypto/identity.js'
import { isAvatar } from '../src/lib/avatar.js'
import { importCallKey, sealFrame, openFrame, packFrames, unpackFrames, createReplay } from '../src/crypto/callFrame.js'
import { slotOf, isDue, windowStart, SLOT_MS, WINDOW_MS, STALE_MS } from '../src/lib/schedule.js'
import { createVault } from '../src/crypto/vault.js'
import { openDb } from '../src/crypto/db.js'
import { b64, b64url, hex, utf8, unutf8, random, concat } from '../src/lib/bytes.js'
import { sha256 } from '@noble/hashes/sha2.js'

const nodes = []
beforeEach(() => { nodes.length = 0 })
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
        m.origin[hex(p.dest)].emit('packet', { packet: encodePacket({ type: TYPE.REPLY, dest: p.dest, hops: m.hopsToOrigin ?? 1, payload: p.payload }), from: 'self' })
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
const TIMING = { ack: 1500, verify: 1200, proof: 300, poll: 30, discover: 600, quiet: 150, ring: 500, quietRing: 150 }

async function user(name, timing = TIMING, audio) {
  const mesh = fakeMesh()
  const core = createCore({ mesh, dbName: `db-${name}-${hex(random(4))}`, notifier: () => {}, timing, ...(audio && { audio }) })
  await core.init()
  await core.createProfile(name)
  return { mesh, core, state: core.state, id: core.state.profile.ripploId, link: core.myInviteLink() }
}
const unlock = async (a, b) => {
  await a.core.sendText(b.id, 'hi')
  await waitFor(() => b.state.contacts[a.id]?.card)
  await b.core.sendText(a.id, 'hello')
  await waitFor(() => a.state.contacts[b.id].cardAck)
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
    await unlock(a, b)
    const data = random(100 * 1024)
    const m = await a.core.sendAttachment(b.id, new Blob([data], { type: 'image/png' }), 'image')
    await waitFor(() => m.status === 'delivered', 8000)
    expect(m.progress).toBe(1)
    const got = await waitFor(() => b.state.messages[a.id]?.find((x) => x.att), 8000)
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

describe('changing the display name', () => {
  it('rejects empty names and updates the contact, its chat, the card and the link', async () => {
    const a = await user('Alice'), b = await user('Bob')
    expect(await codeOf(a.core.setName('  '))).toBe('bad_name')
    await a.core.addContactFromLink(b.link)
    await a.core.sendText(b.id, 'hi')
    await waitFor(() => b.state.contacts[a.id]?.card)
    await a.core.setName('Alicja')
    await waitFor(() => b.state.contacts[a.id].name === 'Alicja')
    expect(b.state.chats.find((c) => c.id === a.id).name).toBe('Alicja')
    expect(a.state.profile.name).toBe('Alicja')
    expect(a.state.profile.ripploId).toBe(a.id)
    expect(parseLink(a.core.myInviteLink()).name).toBe('Alicja')
  })
})

describe('invitations and visibility', () => {
  const personOf = (u) => ({ id: u.id, name: u.state.profile.name, card: b64(parseLink(u.link).card), hops: 1 })

  it('invite shows as a request, accept creates the chat on both sides', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.refreshPeople()
    await a.core.invite(a.state.people.find((p) => p.id === b.id))
    expect(a.state.contacts[b.id].request).toBe('out')
    expect(a.state.chats.some((c) => c.id === b.id)).toBe(false)
    await waitFor(() => b.state.contacts[a.id]?.request === 'in')
    expect(b.state.chats.some((c) => c.id === a.id)).toBe(false)
    await b.core.acceptRequest(a.id)
    expect(b.state.contacts[a.id].request).toBeUndefined()
    expect(b.state.chats.some((c) => c.id === a.id)).toBe(true)
    await waitFor(() => a.state.contacts[b.id].request === undefined)
    expect(a.state.chats.some((c) => c.id === b.id)).toBe(true)
    await a.core.sendText(b.id, 'hello after accept')
    await waitFor(() => b.state.messages[a.id]?.length)
  })

  it('decline removes the pending contact on both sides', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.invite(personOf(b))
    await waitFor(() => b.state.contacts[a.id]?.request === 'in')
    await b.core.declineRequest(a.id)
    expect(b.state.contacts[a.id]).toBeUndefined()
    await waitFor(() => !a.state.contacts[b.id])
  })

  it('ignores chat messages from a requester until accepted', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.invite(personOf(b))
    await waitFor(() => b.state.contacts[a.id]?.request === 'in')
    delete a.state.contacts[b.id].request
    await a.core.sendText(b.id, 'spam')
    await new Promise((r) => setTimeout(r, 200))
    expect(b.state.messages[a.id]?.length || 0).toBe(0)
  })

  it('a hidden user is not found in mesh search', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await b.core.saveSettings({ hidden: true })
    await a.core.refreshPeople()
    expect(a.state.people.some((p) => p.id === b.id)).toBe(false)
    await b.core.saveSettings({ hidden: false })
    await a.core.refreshPeople()
    expect(a.state.people.some((p) => p.id === b.id)).toBe(true)
  })

  it('hello is answered when the peer asks for it', async () => {
    const a = await user('Alice'), b = await user('Bob')
    connect(a.mesh, b.mesh)
    await waitFor(() => a.state.neighbors[0]?.card && b.state.neighbors[0]?.card)
    expect(a.state.neighbors[0].card.id).toBe(b.id)
  })
})

describe('voice messages', () => {
  it('carries the duration and the waveform to the receiver and bounds them', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    await unlock(a, b)
    const wave = Array.from({ length: 40 }, (_, i) => (i * 6) % 256)
    const m = await a.core.sendAttachment(b.id, new Blob([random(2000)], { type: 'audio/webm' }), 'voice', { duration: 3, wave })
    await waitFor(() => m.status === 'delivered', 8000)
    const got = await waitFor(() => b.state.messages[a.id]?.find((x) => x.att), 8000)
    expect(got.att).toMatchObject({ kind: 'voice', mime: 'audio/webm', duration: 3 })
    expect(got.att.wave).toEqual(wave)
    expect(m.att.duration).toBe(3)
  })

  it('drops an oversized waveform and a silly duration', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    await unlock(a, b)
    const m = await a.core.sendAttachment(b.id, new Blob([random(500)], { type: 'audio/webm' }), 'voice', { duration: 99999, wave: new Array(500).fill(9) })
    expect(m.att.wave).toBeUndefined()
    expect(m.att.duration).toBe(3600)
  })
})

describe('mesh search', () => {
  it('keeps listening after a dead end so late replies from far phones are not lost', async () => {
    const a = await user('Alice', { ...TIMING, quiet: 700, quietRing: 700, ring: 3000, discover: 3000 }), b = await user('Bob')
    const send = b.mesh.send
    b.mesh.send = async (pkt) => {
      if (decodePacket(pkt).type === TYPE.REPLY) await new Promise((r) => setTimeout(r, 350))
      return send(pkt)
    }
    await a.core.refreshPeople()
    expect(a.state.people.some((p) => p.id === b.id)).toBe(true)
  })

  it('finishes at once when there are no neighbors', async () => {
    const a = await user('Alice', { ...TIMING, quiet: 5000, quietRing: 5000, ring: 5000, discover: 5000 })
    a.mesh.send = async () => ({ neighbors: 0 })
    const t0 = Date.now()
    await a.core.refreshPeople()
    expect(Date.now() - t0).toBeLessThan(1000)
  })
})

describe('nightly scan slots', () => {
  const day = new Date(2026, 10, 22, 12).getTime()
  const tags = Array.from({ length: 300 }, () => hex(random(16)))

  it('assigns each phone a stable 15 s slot inside 02:00-05:00', () => {
    for (const tag of tags) {
      const s = slotOf(tag)
      expect(s).toBeGreaterThanOrEqual(0)
      expect(s).toBeLessThan(WINDOW_MS / SLOT_MS)
      expect(slotOf(tag)).toBe(s)
    }
    expect(new Set(tags.map(slotOf)).size).toBeGreaterThan(150)
  })

  it('is due only after its own slot, inside the window and when stale', () => {
    const tag = '00000000' + '0'.repeat(24)
    const start = windowStart(day)
    expect(slotOf(tag)).toBe(0)
    expect(isDue(tag, 0, start - 1)).toBe(false)
    expect(isDue(tag, 0, start)).toBe(true)
    const late = '0000000a' + '0'.repeat(24)
    expect(slotOf(late)).toBe(10)
    expect(isDue(late, 0, start + 9 * SLOT_MS)).toBe(false)
    expect(isDue(late, 0, start + 10 * SLOT_MS)).toBe(true)
    expect(isDue(late, start + 10 * SLOT_MS, start + 11 * SLOT_MS)).toBe(false)
    expect(isDue(late, start - STALE_MS, start + 10 * SLOT_MS)).toBe(true)
    expect(isDue(late, 0, start + WINDOW_MS)).toBe(false)
  })
})

describe('people search and the 20 person cap', () => {
  it('keeps at most 20 people and lets closer ones replace the farthest', async () => {
    const a = await user('Alice')
    const far = await Promise.all(Array.from({ length: 24 }, (_, i) => user(`Far${i}`)))
    far.forEach((u) => { u.mesh.hopsToOrigin = 6 })
    const near = await Promise.all(Array.from({ length: 3 }, (_, i) => user(`Near${i}`)))
    near.forEach((u) => { u.mesh.hopsToOrigin = 1 })
    await a.core.refreshPeople()
    expect(a.state.people).toHaveLength(20)
    for (const n of near) expect(a.state.people.some((p) => p.id === n.id)).toBe(true)
    const hops = a.state.people.map((p) => p.hops)
    expect(hops).toEqual([...hops].sort((x, y) => x - y))
  }, 20000)

  it('finds a person by exact name or id, case-insensitively, and never sends the name in clear', async () => {
    const a = await user('Alice'), b = await user('Bob Builder'), c = await user('Carol')
    const sent = []
    const send = a.mesh.send
    a.mesh.send = (pkt) => { sent.push(unutf8(decodePacket(pkt).payload)); return send(pkt) }
    await a.core.searchPeople('  bob   BUILDER ')
    expect(a.state.people.map((p) => p.id)).toEqual([b.id])
    expect(a.state.peopleQuery).toBe('bob   BUILDER')
    expect(sent.join('')).not.toMatch(/bob/i)
    await a.core.searchPeople(c.id.replace(/(.{4})/g, '$1-').slice(0, -1))
    expect(a.state.people.map((p) => p.id)).toEqual([c.id])
    await a.core.searchPeople('Bo')
    expect(a.state.people).toHaveLength(0)
  })

  it('restores the previous list when the search is cleared', async () => {
    const a = await user('Alice'), b = await user('Bob'), c = await user('Carol')
    await a.core.refreshPeople()
    expect(a.state.people).toHaveLength(2)
    await a.core.searchPeople('Bob')
    expect(a.state.people.map((p) => p.id)).toEqual([b.id])
    await a.core.searchPeople('')
    expect(a.state.people.map((p) => p.id).sort()).toEqual([b.id, c.id].sort())
    expect(a.state.peopleQuery).toBe('')
  })

  it('answers only inside the requested distance ring', async () => {
    const a = await user('Alice'), b = await user('Bob')
    const replies = []
    const send = b.mesh.send
    b.mesh.send = (pkt) => { if (decodePacket(pkt).type === TYPE.REPLY) replies.push(1); return send(pkt) }
    const ask = (hops, body) => b.mesh.emit('packet', { packet: encodePacket({ type: TYPE.DISCOVER, id: newId(), hops, payload: utf8(JSON.stringify(body)) }), from: a.mesh.node })
    ask(3, { t: 'who', h: 2 })
    ask(0, { t: 'who', lo: 1 })
    await new Promise((r) => setTimeout(r, 100))
    expect(replies).toHaveLength(0)
    ask(2, { t: 'who', h: 3, lo: 1 })
    await waitFor(() => replies.length === 1)
  })
})

function fakeAudio() {
  const e = { frames: [], muted: false, stopped: false, handler: null }
  e.start = async (handler) => { e.handler = handler }
  e.play = (f) => { e.frames.push(...f) }
  e.setMuted = (m) => { e.muted = m }
  e.stop = () => { e.stopped = true }
  e.api = { supported: () => true, create: async () => e }
  return e
}

describe('call frame crypto', () => {
  const id = random(8)
  it('round-trips and rejects a wrong key, call id, role, tampering and replays', async () => {
    const key = await importCallKey(random(32)), other = await importCallKey(random(32))
    const plain = packFrames([new Uint8Array([1, 2, 3]), new Uint8Array([4])])
    const pkt = await sealFrame(key, id, 0, 7, plain)
    const ok = await openFrame(key, id, 0, pkt)
    expect(ok.seq).toBe(7)
    expect(unpackFrames(ok.plain).map((f) => Array.from(f))).toEqual([[1, 2, 3], [4]])
    await expect(openFrame(other, id, 0, pkt)).rejects.toBeTruthy()
    await expect(openFrame(key, random(8), 0, pkt)).rejects.toBeTruthy()
    await expect(openFrame(key, id, 1, pkt)).rejects.toBeTruthy()
    const bad = pkt.slice()
    bad[bad.length - 1] ^= 1
    await expect(openFrame(key, id, 0, bad)).rejects.toBeTruthy()
    const seqSwap = pkt.slice()
    seqSwap[12] ^= 1
    await expect(openFrame(key, id, 0, seqSwap)).rejects.toBeTruthy()
  })

  it('uses a different nonce per role and per sequence number', async () => {
    const key = await importCallKey(random(32))
    const a = await sealFrame(key, id, 0, 1, new Uint8Array([5, 5, 5]))
    const b = await sealFrame(key, id, 1, 1, new Uint8Array([5, 5, 5]))
    const c = await sealFrame(key, id, 0, 2, new Uint8Array([5, 5, 5]))
    expect(hex(a.subarray(13))).not.toBe(hex(b.subarray(13)))
    expect(hex(a.subarray(13))).not.toBe(hex(c.subarray(13)))
  })

  it('replay window accepts each sequence once and refuses old ones', () => {
    const r = createReplay(8)
    expect([0, 1, 1, 3, 2, 2, 20, 5, 19].map((s) => r.accept(s))).toEqual([true, true, false, true, true, false, true, false, true])
  })

  it('refuses malformed frame packing', () => {
    expect(() => unpackFrames(new Uint8Array([2, 0, 1, 9]))).toThrow()
    expect(() => unpackFrames(new Uint8Array([1, 0, 1, 9, 0]))).toThrow()
    expect(() => packFrames([])).toThrow()
  })
})

describe('voice calls', () => {
  async function pair() {
    const ea = fakeAudio(), eb = fakeAudio()
    const a = await user('Alice', { ...TIMING, callHold: 100 }, ea.api), b = await user('Bob', { ...TIMING, callHold: 100 }, eb.api)
    await a.core.addContactFromLink(b.link)
    await b.core.addContactFromLink(a.link)
    connect(a.mesh, b.mesh)
    await waitFor(() => a.state.neighbors[0]?.card && b.state.neighbors[0]?.card)
    return { a, b, ea, eb }
  }

  it('rings, answers, carries encrypted audio both ways, drops replays and hangs up', async () => {
    const { a, b, ea, eb } = await pair()
    const wire = []
    const sendApp = a.mesh.sendApp
    a.mesh.sendApp = (node, payload) => { if (payload[0] === 1) wire.push(payload); return sendApp(node, payload) }
    await a.core.startCall(b.id)
    await waitFor(() => b.state.call?.status === 'ringing')
    expect(b.state.call).toMatchObject({ peer: a.id, dir: 'in' })
    await b.core.acceptCall()
    await waitFor(() => a.state.call?.status === 'active' && b.state.call?.status === 'active')
    await ea.handler([new Uint8Array([1, 2, 3]), new Uint8Array([4, 5])])
    await waitFor(() => eb.frames.length === 2)
    expect(Array.from(eb.frames[0])).toEqual([1, 2, 3])
    expect(wire[0].length).toBeGreaterThan(29)
    const inject = (payload) => b.mesh.emit('packet', { packet: encodePacket({ type: TYPE.APP, payload }), from: a.mesh.node })
    inject(wire[0])
    const flipped = wire[0].slice()
    flipped[flipped.length - 2] ^= 1
    inject(flipped)
    await new Promise((r) => setTimeout(r, 150))
    expect(eb.frames).toHaveLength(2)
    await eb.handler([new Uint8Array([9, 9, 9])])
    await waitFor(() => ea.frames.length === 1)
    await b.core.setMuted(true)
    expect(eb.muted).toBe(true)
    expect(b.state.call.muted).toBe(true)
    await b.core.hangUp()
    expect(b.state.call.status).toBe('ended')
    await waitFor(() => a.state.call?.status === 'ended')
    expect(ea.stopped && eb.stopped).toBe(true)
    expect(b.state.messages[a.id].some((m) => m.from === 'system' && /\d+:\d\d/.test(m.text))).toBe(true)
    await waitFor(() => !a.state.call && !b.state.call)
  })

  it('decline, cancel and busy', async () => {
    const { a, b } = await pair()
    await a.core.startCall(b.id)
    await waitFor(() => b.state.call?.status === 'ringing')
    await b.core.hangUp()
    await waitFor(() => a.state.call?.reason === 'declined')
    await waitFor(() => !a.state.call && !b.state.call)
    await a.core.startCall(b.id)
    await waitFor(() => b.state.call?.status === 'ringing')
    expect(await codeOf(a.core.startCall(b.id))).toBe('call_busy')
    await a.core.hangUp()
    await waitFor(() => b.state.call?.reason === 'missed')
    expect(a.state.call.reason).toBe('cancelled')
  })

  it('refuses a call without a direct link or without audio support', async () => {
    const a = await user('Alice', TIMING, fakeAudio().api), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    expect(await codeOf(a.core.startCall(b.id))).toBe('call_no_link')
    const off = await user('Off', TIMING, { supported: () => false, create: async () => { throw new Error('x') } })
    const c = await user('Carol')
    await off.core.addContactFromLink(c.link)
    connect(off.mesh, c.mesh)
    await waitFor(() => off.state.neighbors[0]?.card)
    expect(await codeOf(off.core.startCall(c.id))).toBe('call_unsupported')
  })

  it('stops ringing when nobody answers', async () => {
    const ea = fakeAudio(), eb = fakeAudio()
    const a = await user('Alice', { ...TIMING, callRing: 200, callHold: 100 }, ea.api), b = await user('Bob', { ...TIMING, callRing: 5000, callHold: 100 }, eb.api)
    await a.core.addContactFromLink(b.link)
    await b.core.addContactFromLink(a.link)
    connect(a.mesh, b.mesh)
    await waitFor(() => a.state.neighbors[0]?.card && b.state.neighbors[0]?.card)
    await a.core.startCall(b.id)
    await waitFor(() => a.state.call?.reason === 'noanswer')
    await waitFor(() => b.state.call?.reason === 'missed')
  })

  it('ignores call signals from a contact that only sent an invitation', async () => {
    const ea = fakeAudio(), eb = fakeAudio()
    const a = await user('Alice', TIMING, ea.api), b = await user('Bob', TIMING, eb.api)
    connect(a.mesh, b.mesh)
    await waitFor(() => a.state.neighbors[0]?.card && b.state.neighbors[0]?.card)
    await a.core.invite({ id: b.id, name: 'Bob', card: b64(parseLink(b.link).card), hops: 1 })
    await waitFor(() => b.state.contacts[a.id]?.request === 'in')
    await a.core.startCall(b.id).catch(() => {})
    await new Promise((r) => setTimeout(r, 200))
    expect(b.state.call).toBeNull()
  })

  it('does not ring for someone who only wrote first, until you reply or add them', async () => {
    const ea = fakeAudio(), eb = fakeAudio()
    const a = await user('Alice', { ...TIMING, callRing: 300, callHold: 100 }, ea.api), b = await user('Bob', TIMING, eb.api)
    await a.core.addContactFromLink(b.link)
    connect(a.mesh, b.mesh)
    await waitFor(() => a.state.neighbors[0]?.card && b.state.neighbors[0]?.card)
    await a.core.startCall(b.id)
    await new Promise((r) => setTimeout(r, 250))
    expect(b.state.call).toBeNull()
    expect(b.state.contacts[a.id]?.addedVia).toBe('incoming')
    expect(await codeOf(b.core.startCall(a.id))).toBe('call_no_contact')
    await waitFor(() => a.state.call?.reason === 'noanswer')
    await b.core.sendText(a.id, 'hi')
    await waitFor(() => b.state.contacts[a.id].cardSent)
    await waitFor(() => !a.state.call)
    await a.core.startCall(b.id)
    await waitFor(() => b.state.call?.status === 'ringing')
  })

  it('ignores an offer that is older than the stale window', async () => {
    const { a, b } = await pair()
    const seal = a.mesh.signalSeal
    a.mesh.signalSeal = (tag, pt) => {
      const o = JSON.parse(unutf8(pt))
      if (o.t === 'call' && o.k === 'offer') o.ts = Date.now() - 10 * 60 * 1000
      return seal(tag, utf8(JSON.stringify(o)))
    }
    await a.core.startCall(b.id)
    await new Promise((r) => setTimeout(r, 250))
    expect(b.state.call).toBeNull()
    await a.core.hangUp()
  })
})

describe('request hygiene', () => {
  it('does not send profile changes or a name/photo with a decline to people you have not accepted', async () => {
    const a = await user('Alice'), b = await user('Bob')
    const seen = []
    const seal = b.mesh.signalSeal
    b.mesh.signalSeal = (tag, pt) => { seen.push(JSON.parse(unutf8(pt))); return seal(tag, pt) }
    await a.core.invite({ id: b.id, name: 'Bob', card: b64(parseLink(b.link).card), hops: 1 })
    await waitFor(() => b.state.contacts[a.id]?.request === 'in')
    await b.core.setAvatar(b64(concat(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]), new Uint8Array(50))))
    await b.core.setName('Robert')
    await new Promise((r) => setTimeout(r, 200))
    expect(seen).toHaveLength(0)
    await b.core.declineRequest(a.id)
    await waitFor(() => seen.length === 1)
    expect(seen[0]).toEqual({ t: 'decline' })
  })

  it('scanning the QR of someone who invited you accepts the request', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.invite({ id: b.id, name: 'Bob', card: b64(parseLink(b.link).card), hops: 1 })
    await waitFor(() => b.state.contacts[a.id]?.request === 'in')
    await b.core.addContactFromLink(a.link, 'qr')
    expect(b.state.contacts[a.id].request).toBeUndefined()
    expect(b.state.chats.some((c) => c.id === a.id)).toBe(true)
  })

  it('does not open a chat with someone you only invited', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.invite({ id: b.id, name: 'Bob', card: b64(parseLink(b.link).card), hops: 1 })
    expect(await codeOf(a.core.sendText(b.id, 'x'))).toBe('no_chat')
  })
})

describe('media from and to people who have not replied', () => {
  it('blocks sending media until the other person answers, text is fine', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    const blob = new Blob([random(300)], { type: 'image/png' })
    expect(await codeOf(a.core.sendAttachment(b.id, blob, 'image'))).toBe('media_locked')
    await a.core.sendText(b.id, 'hi')
    await waitFor(() => b.state.contacts[a.id]?.card)
    expect(await codeOf(a.core.sendAttachment(b.id, blob, 'image'))).toBe('media_locked')
    await b.core.sendText(a.id, 'hello')
    await waitFor(() => a.state.contacts[b.id].cardAck)
    const m = await a.core.sendAttachment(b.id, blob, 'image')
    await waitFor(() => m.status === 'delivered', 8000)
  })

  it('drops a media pointer from a stranger who wrote first until you reply', async () => {
    const a = await user('Alice'), b = await user('Bob')
    await a.core.addContactFromLink(b.link)
    await a.core.sendText(b.id, 'hi')
    await waitFor(() => b.state.contacts[a.id]?.card)
    a.state.contacts[b.id].cardAck = true
    const blob = new Blob([random(300)], { type: 'image/png' })
    const m = await a.core.sendAttachment(b.id, blob, 'image')
    await waitFor(() => m.status === 'delivered', 8000)
    await new Promise((r) => setTimeout(r, 200))
    expect((b.state.messages[a.id] || []).some((x) => x.att)).toBe(false)
    await b.core.sendText(a.id, 'ok')
    await waitFor(() => b.state.contacts[a.id].cardSent)
    const m2 = await a.core.sendAttachment(b.id, blob, 'image')
    await waitFor(() => m2.status === 'delivered', 8000)
    await waitFor(() => (b.state.messages[a.id] || []).some((x) => x.att), 8000)
  })

  it('allows an unlimited number of pending requests', async () => {
    const b = await user('Bob')
    const senders = await Promise.all(Array.from({ length: 25 }, (_, i) => user(`S${i}`)))
    for (const s of senders) await s.core.invite({ id: b.id, name: 'Bob', card: b64(parseLink(b.link).card), hops: 1 })
    await waitFor(() => Object.values(b.state.contacts).filter((c) => c.request === 'in').length === 25, 10000)
  }, 20000)
})
