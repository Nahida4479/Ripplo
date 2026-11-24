process.env.TZ = 'Europe/Warsaw'
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sha256 } from '@noble/hashes/sha2.js'
import * as B from '../src/lib/bytes.js'
import * as ident from '../src/crypto/identity.js'
import { createVault } from '../src/crypto/vault.js'
import * as att from '../src/crypto/attachment.js'
import * as cf from '../src/crypto/callFrame.js'
import * as qr from '../src/lib/qrparts.js'
import * as sch from '../src/lib/schedule.js'
import { isAvatar, MAX_AVATAR } from '../src/lib/avatar.js'
import { isCodedLink } from '../src/lib/linkLabel.js'
import { createGithub } from '../src/lib/githubCache.js'
import * as pk from '../src/mesh/packet.js'
import { Router } from '../src/mesh/router.js'
import { createDevSignal } from '../src/mesh/devSignal.js'
import { createState } from '../src/core/state.js'

const { hex, b64, b64url, utf8, concat } = B
let rngState = null
const seed = (label) => { rngState = { label, n: 0, buf: new Uint8Array(0) } }
const stream = (n) => {
  const r = rngState
  while (r.buf.length < n) r.buf = concat(r.buf, sha256(utf8(`${r.label}#${r.n++}`)))
  const out = r.buf.slice(0, n)
  r.buf = r.buf.slice(n)
  return out
}
crypto.getRandomValues = (a) => { a.set(stream(a.length)); return a }
const bytes = (label, n) => { seed(label); return stream(n) }
const tryv = async (f) => {
  try { return await f() } catch (e) { return { error: e.code || e.message } }
}
const out = {}
const G = (name, items) => { out[name] = items }

const inputs = [[], [0], [255], [0, 1], [255, 255], [1, 2, 3], [250, 251, 252, 253], [0, 0, 0, 0, 0], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], [...Array(32).keys()], [...Array(33).keys()].map((i) => 255 - i)]
G('bytes', {
  base32: inputs.map((i) => ({ in: hex(Uint8Array.from(i)), out: B.base32(Uint8Array.from(i)) })),
  b64: inputs.map((i) => { const u = Uint8Array.from(i); return { in: hex(u), b64: b64(u), b64url: b64url(u), back: hex(B.unb64url(b64url(u))), back64: hex(B.unb64(b64(u))) } }),
  unb64urlBad: ['a+b', 'a/b', 'ab=', 'a b', '!!', 'AAAA', 'AAA', 'AA', 'A'].map((s) => ({ in: s, out: (() => { try { return hex(B.unb64url(s)) } catch (e) { return { error: e.message } } })() })),
  u32: [0, 1, 255, 256, 65535, 65536, 0x7fffffff, 0x80000000, 0xdeadbeef, 0xffffffff].map((n) => ({ in: n, out: hex(B.u32(n)), back: B.readU32(B.u32(n), 0) })),
  readU32: ['80000000', '00000001', 'ffffffff', '8badf00d', '7fffffff', '01020304'].map((h) => ({ in: h, out: B.readU32(B.unhex(h), 0) })),
  readU32Offset: { in: '00aa55ff00ff80', off: 2, out: B.readU32(B.unhex('00aa55ff00ff80'), 2) },
  equal: [['01', '01'], ['01', '02'], ['', ''], ['0102', '01'], ['ff', 'fe']].map(([a, b]) => ({ a, b, out: B.equal(B.unhex(a), B.unhex(b)) })),
  concat: { parts: ['', '01', '0203'], out: hex(concat(B.unhex(''), B.unhex('01'), B.unhex('0203'))) },
  utf8: ['', 'abc', 'Łódź', 'ﬁ', '😀', 'á'].map((s) => ({ in: s, out: hex(utf8(s)), back: B.unutf8(utf8(s)) })),
})

const bundle = (label) => {
  const b = bytes(label, 1776)
  b[0] = 2
  b[5] = 5
  return b
}
const bA = bundle('bundleA')
const bB = bundle('bundleB')
const hostile = [
  'Alice', '  padded  ', 'a‮bidi‬', 'x‎y‏z', 'c1\u0085\u009fctl', 'del\u007fx', 'nul\u0000tab\tnl\nx', '⁦iso⁩',
  'A'.repeat(41), 'B'.repeat(40), 'C'.repeat(39) + '😀', 'D'.repeat(40) + '😀', 'Zażółć gęślą jaźń', '', '   ', '\u0000\u0001',
]
const cards = ['Alice', 'Łódź', '😀 emoji', 'A'.repeat(60), ''].map((n) => ({ name: n, card: ident.encodeCard(n, bA) }))
const cardOf = ident.encodeCard('Alice', bA)
const tok = bytes('tok', 8)
const linkNoTok = ident.encodeLink(cardOf)
const linkTok = ident.encodeLink(cardOf, tok)
const parseOut = (t) => { try { const v = ident.parseLink(t); return { id: v.id, tag: hex(v.tag), ik: hex(v.ik), name: v.name, bundle: hex(v.bundle), card: hex(v.card), token: v.token ?? null } } catch (e) { return { error: e.code } } }
const corruptCard = cardOf.slice(); corruptCard[corruptCard.length - 1] ^= 1
const badCheck = linkNoTok.replace(/\.[A-Za-z0-9_-]{8}$/, '.AAAAAAAA')
G('identity', {
  deriveIds: [bA, bB].map((b) => { const ik = b.slice(5, 38); const d = ident.deriveIds(ik); return { ik: hex(ik), tag: hex(d.tag), ripploId: d.ripploId, formatted: ident.formatId(d.ripploId) } }),
  cleanName: hostile.map((s) => ({ in: s, out: ident.cleanName(s) })),
  cleanNameNull: [null, undefined, 42].map((v) => ({ in: String(v), out: ident.cleanName(v) })),
  encodeCard: cards.map((c) => ({ name: c.name, bundle: hex(bA), out: hex(c.card) })),
  encodeLink: [{ card: hex(cardOf), token: null, out: linkNoTok }, { card: hex(cardOf), token: hex(tok), out: linkTok }],
  webLink: [linkNoTok, linkTok].flatMap((l) => ['en', 'pl', undefined].map((lang) => ({ in: l, lang: lang ?? null, out: ident.webLink(l, lang) }))),
  webLinkBad: { in: 'https://x', out: (() => { try { ident.webLink('https://x', 'en') } catch (e) { return { error: e.code } } })() },
  parseLink: [linkNoTok, linkTok, ident.webLink(linkNoTok, 'en'), ident.webLink(linkTok, 'pl'), `  ${linkTok.slice(0, 30)}\n ${linkTok.slice(30)} `, badCheck, 'ripplo://add/AAAA.BBBBBBBB', 'garbage', `ripplo://add/${b64url(corruptCard)}.${b64url(sha256(corruptCard).slice(0, 6))}`, `ripplo://add/${b64url(cardOf.slice(0, 100))}.${b64url(sha256(cardOf.slice(0, 100)).slice(0, 6))}`].map((t) => ({ in: t, out: parseOut(t) })),
  checkCardBad: [new Uint8Array(0), Uint8Array.of(1, 1), cardOf.slice(0, -1), concat(Uint8Array.of(2, 0), bA), concat(Uint8Array.of(2, 1, 65), new Uint8Array(1776))].map((c) => ({ in: hex(c), out: (() => { try { ident.checkCard(c); return 'ok' } catch (e) { return { error: e.code } } })() })),
})

const mesh = (k) => ({ getDbKey: async () => ({ key: k, insecure: false }) })
const dbKey = bytes('dbkey', 32)
const vaultCases = [['empty', 0, ''], ['short', 5, 'store/key'], ['block', 16, 'messages/abc'], ['long', 300, 'kv/profile'], ['noaad', 40, null]]
const vault = await createVault(mesh(dbKey))
const vaultOut = []
for (const [name, len, aadS] of vaultCases) {
  seed('vault:' + name)
  const pt = stream(len)
  const aad = aadS === null ? undefined : utf8(aadS)
  const sealed = await vault.seal(pt, aad)
  const opened = await vault.open(sealed, aad)
  const wrong = await tryv(() => vault.open(sealed, utf8('other/aad')))
  const tamper = sealed.slice(); tamper[tamper.length - 1] ^= 1
  vaultOut.push({ name, key: hex(dbKey), aad: aadS, plain: hex(pt), nonce: hex(sealed.subarray(0, 12)), sealed: hex(sealed), opened: hex(opened), wrongAad: wrong.error ? 'fail' : 'ok', tamper: (await tryv(() => vault.open(tamper, aad))).error ? 'fail' : 'ok' })
}
G('vault', vaultOut)

const encOut = []
for (const [name, len] of [['empty', 0], ['one', 1], ['small', 100], ['chunk', att.CHUNK], ['multi', att.CHUNK * 2 + 777]]) {
  seed('att:' + name)
  const pt = bytes('attpt:' + name, len)
  seed('att:' + name)
  const e = await att.encryptFile(pt)
  const dec = await att.decryptFile(e.ct, e.key)
  const total = att.chunkCount(e.ct)
  const attId = bytes('attid:' + name, 16)
  const idxs = [...new Set([0, total - 1])]
  const chunks = idxs.map((i) => { const p = att.chunkPayload(attId, e.ct, i, total); const q = att.parseChunk(p); return { index: i, payload: hex(p), parsed: { attId: hex(q.attId), index: q.index, total: q.total, bytes: hex(q.bytes) } } })
  encOut.push({ name, plain: hex(pt), key: hex(e.key), nonce: hex(e.ct.subarray(0, 12)), ct: hex(e.ct), sha256: hex(e.sha256), decrypted: hex(dec), chunkCount: total, attId: hex(attId), chunks })
}
G('attachment', {
  encrypt: encOut,
  chunkSize: att.CHUNK,
  parseChunkBad: [new Uint8Array(24), Uint8Array.of(3, ...new Array(30).fill(0)), new Uint8Array(0)].map((p) => ({ in: hex(p), out: (() => { try { att.parseChunk(p); return 'ok' } catch (e) { return { error: e.message } } })() })),
  decryptBadKey: await (async () => { const e = await (async () => { seed('att:one'); return att.encryptFile(Uint8Array.of(1)) })(); return { ct: hex(e.ct), key: hex(bytes('wrongkey', 32)), out: (await tryv(() => att.decryptFile(e.ct, bytes('wrongkey', 32)))).error ? 'fail' : 'ok' } })(),
})

const callKeyRaw = bytes('callkey', 32)
const callKey = await cf.importCallKey(callKeyRaw)
const callId = bytes('callid', 8)
const frameOut = []
for (const role of [0, 1]) for (const seq of [0, 1, 2 ** 31, 0xffffffff]) {
  const plain = bytes(`frame:${role}:${seq}`, 40)
  const sealed = await cf.sealFrame(callKey, callId, role, seq, plain)
  const o = await cf.openFrame(callKey, callId, role, sealed)
  const wrongRole = await tryv(() => cf.openFrame(callKey, callId, 1 - role, sealed))
  frameOut.push({ role, seq, plain: hex(plain), sealed: hex(sealed), openedSeq: o.seq, opened: hex(o.plain), wrongRole: wrongRole.error ? 'fail' : 'ok' })
}
const mk = (n, len) => Array.from({ length: n }, (_, i) => bytes(`pf:${n}:${len}:${i}`, len + i))
const packs = [mk(1, 20), mk(8, 60), mk(3, 1000), [bytes('max', 1275)]].map((frames) => { const p = cf.packFrames(frames); return { frames: frames.map(hex), packed: hex(p), unpacked: cf.unpackFrames(p).map(hex) } })
const badPack = [[], mk(9, 10), [new Uint8Array(0)], [new Uint8Array(1276)]].map((frames) => ({ frames: frames.map(hex), out: (() => { try { cf.packFrames(frames); return 'ok' } catch (e) { return { error: e.message } } })() }))
const badUnpack = ['00', '09', '0100', '010001', '01000501', '0100010102', '01ffff'].map((h) => ({ in: h, out: (() => { try { return cf.unpackFrames(B.unhex(h)).map(hex) } catch (e) { return { error: e.message } } })() }))
const openBad = []
const good = await cf.sealFrame(callKey, callId, 0, 5, Uint8Array.of(1, 2, 3))
const wrongCall = good.slice(); wrongCall[1] ^= 1
const wrongTag = good.slice(); wrongTag[0] = 2
for (const [name, p] of [['short', good.slice(0, 28)], ['tag', wrongTag], ['callid', wrongCall], ['tamper', (() => { const t = good.slice(); t[t.length - 1] ^= 1; return t })()]]) openBad.push({ name, in: hex(p), out: (await tryv(() => cf.openFrame(callKey, callId, 0, p))).error })
const replayTrace = (size, seqs) => { const r = cf.createReplay(size); return { size, seqs, out: seqs.map((s) => r.accept(s)) } }
G('callFrame', {
  key: hex(callKeyRaw), callId: hex(callId), tag: cf.FRAME_TAG,
  sealFrame: frameOut, packFrames: packs, packFramesBad: badPack, unpackFramesBad: badUnpack, openFrameBad: openBad,
  replay: [replayTrace(64, [0, 1, 1, 5, 100, 36, 37, 35, 36, 164, 99, 100, 0]), replayTrace(4, [10, 9, 7, 6, 11, 7, 12, 8, 9, 20, 15, 16]), replayTrace(64, [0xffffffff, 0xfffffffe, 0xffffffff])],
})

const names = ['Anna', 'anna', 'ANNA', 'Łódź', 'ŁÓDŹ', 'ŻÓŁW', 'żółw', 'Zażółć  gęślą   jaźń', 'Straße', 'STRASSE', 'İstanbul', 'ıstanbul', 'ＡＢＣ', 'ｱｲｳ', 'ﬁnance', 'ﬃ', 'ǅ', 'Å', 'Å', 'á', 'á', '한', '한', '😀', 'Ⅻ', '㌀', '²³', ' \t leading and trailing \n ', 'tab\tand nbsp　ideo', 'Kelvin', 'Σίσυφος', 'ΣΑΣ', 'Ǆ', 'ᴬ', 'ℌ', '①②', 'ﷺ', 'İ', '', 'ß', 'ẞ']
const normName = (s) => String(s).normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim()
const findHash = (norm) => b64url(sha256(utf8('ripplo-find-v1\0' + norm)).subarray(0, 8))
G('findHash', names.map((n) => ({ name: n, norm: normName(n), normHex: hex(utf8(normName(n))), hash: findHash(normName(n)) })))

const tags = ['00000000', '0000003b', '00000708', 'ffffffff', 'deadbeef', '12345678', '7fffffff', 'abcdef01', '0123456789abcdef0123456789abcdef', 'b8f0c3a1d4e5f6071829304a5b6c7d8e']
const T = (y, m, d, h = 0, mi = 0, s = 0) => new Date(y, m - 1, d, h, mi, s).getTime()
const instants = [T(2026, 1, 15, 1, 59), T(2026, 1, 15, 2, 0), T(2026, 1, 15, 2, 0, 15), T(2026, 1, 15, 4, 59, 59), T(2026, 1, 15, 5, 0), T(2026, 3, 29, 2, 30), T(2026, 3, 29, 3, 30), T(2026, 10, 25, 2, 30), T(2026, 7, 1, 12), T(2026, 12, 31, 23, 59, 59)]
const dueOut = []
for (const tag of tags.slice(0, 5)) for (const now of instants) for (const last of [0, now - 19 * 3600e3, now - 21 * 3600e3]) dueOut.push({ tag, now, last, out: sch.isDue(tag, last, now) })
const slotStart = sch.windowStart(T(2026, 1, 15, 2, 0))
const dueEdge = tags.slice(0, 5).flatMap((tag) => [slotStart + sch.slotOf(tag) * sch.SLOT_MS - 1, slotStart + sch.slotOf(tag) * sch.SLOT_MS, slotStart + sch.WINDOW_MS - 1, slotStart + sch.WINDOW_MS].map((now) => ({ tag, now, last: 0, out: sch.isDue(tag, 0, now) })))
G('schedule', {
  tz: 'Europe/Warsaw', constants: { SLOT_MS: sch.SLOT_MS, WINDOW_MS: sch.WINDOW_MS, STALE_MS: sch.STALE_MS },
  slotOf: tags.map((t) => ({ tag: t, out: sch.slotOf(t) })),
  windowStart: instants.map((n) => ({ now: n, out: sch.windowStart(n) })),
  isDue: dueOut, isDueEdge: dueEdge,
})

const link1900 = 'ripplo://add/' + b64url(bytes('bigcard', 1400)).slice(0, 1887)
const parts1900 = qr.splitLink(link1900)
const asmRun = (texts) => { const a = qr.createAssembler(); return texts.map((t) => { const r = a.add(t); return r === null ? null : r }) }
const shortLink = linkNoTok
const shortParts = qr.splitLink(shortLink)
const exact = 'x'.repeat(qr.PART_SIZE * 2)
const sp = qr.splitLink(link1900)
const mkSet = (l) => qr.splitLink(l)
const lA = 'ripplo://add/' + 'A'.repeat(900), lB = 'ripplo://add/' + 'B'.repeat(900)
const pa = mkSet(lA), pb = mkSet(lB)
const tamperedPart = sp.slice(); tamperedPart[1] = tamperedPart[1].slice(0, -1) + (tamperedPart[1].endsWith('a') ? 'b' : 'a')
G('qrparts', {
  partSize: qr.PART_SIZE,
  splitLink: [link1900, shortLink, 'a', 'x'.repeat(420), 'x'.repeat(421), exact, 'x'.repeat(840 + 1)].map((l) => ({ link: l, parts: qr.splitLink(l) })),
  assemble: [
    { name: 'in-order', parts: sp, out: asmRun(sp) },
    { name: 'reversed', parts: [...sp].reverse(), out: asmRun([...sp].reverse()) },
    { name: 'duplicates', parts: [sp[0], sp[0], sp[1], sp[1], ...sp.slice(2)], out: asmRun([sp[0], sp[0], sp[1], sp[1], ...sp.slice(2)]) },
    { name: 'tampered', parts: tamperedPart, out: asmRun(tamperedPart) },
    { name: 'interleaved-two-sets', parts: [pa[0], pb[0], pa[1], pb[1], pa[2], pb[2]], out: asmRun([pa[0], pb[0], pa[1], pb[1], pa[2], pb[2]]) },
    { name: 'garbage', parts: ['hello', '', 'ripplo://p/short.1.2.x', 'ripplo://p/AAAAAAAA.0.2.x', 'ripplo://p/AAAAAAAA.3.2.x', 'ripplo://p/AAAAAAAA.1.1.x', 'ripplo://p/AAAAAAAA.1.21.x', `ripplo://p/AAAAAAAA.1.2.${'y'.repeat(421)}`, '  ' + sp[0] + '  '], out: asmRun(['hello', '', 'ripplo://p/short.1.2.x', 'ripplo://p/AAAAAAAA.0.2.x', 'ripplo://p/AAAAAAAA.3.2.x', 'ripplo://p/AAAAAAAA.1.1.x', 'ripplo://p/AAAAAAAA.1.21.x', `ripplo://p/AAAAAAAA.1.2.${'y'.repeat(421)}`, '  ' + sp[0] + '  ']) },
    { name: 'total-changes', parts: [sp[0], sp[0].replace(/\.(\d+)\.(\d+)\./, '.1.9.'), ...sp.slice(1)], out: asmRun([sp[0], sp[0].replace(/\.(\d+)\.(\d+)\./, '.1.9.'), ...sp.slice(1)]) },
    (() => {
      const ls = ['p', 'q', 'r', 's', 't'].map((c) => 'ripplo://add/' + c.repeat(900))
      const ps = ls.map(mkSet)
      const seq = [...ps.map((x) => x[0]), ps[0][1], ps[0][2], ps[1][1], ps[1][2], ps[4][1], ps[4][2]]
      return { name: 'set-eviction', parts: seq, out: asmRun(seq) }
    })(),
  ],
})

const avatarCases = []
const jpg = (n, tail = 0) => b64(Uint8Array.from({ length: n }, (_, i) => (i === 0 ? 0xff : i === 1 ? 0xd8 : i === 2 ? 0xff : (i * 7 + tail) & 255)))
for (const [name, s] of [['ok-small', jpg(10)], ['ok-max', jpg(MAX_AVATAR)], ['too-big', jpg(MAX_AVATAR + 1)], ['not-jpeg', b64(Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 1))], ['empty', ''], ['bad-chars', 'abc!def='], ['url-safe', b64url(Uint8Array.of(0xff, 0xd8, 0xff, 0xfb, 0xfe))], ['too-long-string', 'A'.repeat(22000)], ['pad3', 'AAA==='], ['two-bytes', b64(Uint8Array.of(0xff, 0xd8))], ['null', null], ['number', 5]]) avatarCases.push({ name, in: s, out: isAvatar(s) })
const hueOf = (name) => [...(name || '?')].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7)
const initialsOf = (name) => (name || '?').trim().split(/\s+/).slice(0, 2).map((w) => [...w][0]).join('').toUpperCase()
const settingsIni = (l) => l.slice(0, 2).toUpperCase()
const avNames = ['Anna Kowalska', 'anna', '', null, undefined, '  spaced   out  name here ', 'Łukasz Żak', 'ﬁnn', 'ßeta', '😀 smile', '😀😀', 'İlker', 'a', 'jan-paweł drugi', '   ', 'ǆ x', 'ＡＢ ＣＤ', 'école', 'Ünal Çelik', 'zażółć']
G('avatar', {
  maxAvatar: MAX_AVATAR, isAvatar: avatarCases,
  hue: avNames.map((n) => ({ name: n, hue: hueOf(n) })),
  initials: avNames.map((n) => ({ name: n, out: initialsOf(n) })),
  settingsInitials: ['octocat', 'a', 'ßx', 'ﬁsh', 'Łk'].map((l) => ({ in: l, out: settingsIni(l) })),
})

G('linkLabel', [null, undefined, {}, { medium: 'ble', note: 'phy coded' }, { medium: 'BLE', note: 'phy coded' }, { medium: 'l2cap', note: 'phy coded' }, { medium: 'L2CAP', note: 'x coded y' }, { medium: 'ble', note: 'phy 1m' }, { medium: 'ble' }, { medium: 'lan', note: 'coded' }, { medium: 'wifi-direct', note: 'phy coded' }, { medium: 'ble', note: 'Coded' }, { medium: 'ble', note: 'uncoded' }, { medium: 'bleX', note: 'coded' }, { medium: null, note: 'coded' }].map((l) => ({ in: l ?? null, undef: l === undefined, out: isCodedLink(l) })))

const mkFetch = (script) => { let i = 0; return async (url, opts) => { const s = script[i++]; return { status: s.status, ok: s.status >= 200 && s.status < 300, headers: { get: (k) => s.headers?.[k.toLowerCase()] ?? null }, json: async () => s.body, _req: { url, headers: opts.headers } } } }
const ghTrace = async () => {
  const store = new Map(); let t = 1_000_000
  const calls = []
  const script = [{ status: 200, headers: { etag: 'W/"1"' }, body: { a: 1 } }, { status: 304 }, { status: 200, headers: { etag: 'W/"2"' }, body: { a: 2 } }, { status: 403, headers: { 'x-ratelimit-reset': String(Math.floor((1_000_000 + 7_200_000) / 1000)) } }, { status: 500 }, { status: 429 }]
  let i = 0
  const fetchFn = async (url, opts) => { const s = script[i++]; calls.push({ url, headers: opts.headers }); return { status: s.status, ok: s.status >= 200 && s.status < 300, headers: { get: (k) => s.headers?.[k.toLowerCase()] ?? null }, json: async () => s.body } }
  const storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => void store.set(k, v) }
  const get = createGithub({ fetchFn, storage, now: () => t })
  const steps = []
  const step = async (label, dt, url, opts) => { t += dt; const r = await tryv(() => get(url, opts)); steps.push({ label, t, url, opts: opts ?? null, result: r, calls: calls.length, storage: Object.fromEntries([...store].sort()) }) }
  await step('fresh', 0, 'https://api/x')
  await step('cache-hit', 1000, 'https://api/x')
  await step('revalidate-304', 31 * 60e3, 'https://api/x')
  await step('maxAge-0-200', 10, 'https://api/x', { maxAge: 0 })
  await step('rate-403-cached', 10, 'https://api/x', { maxAge: 0 })
  await step('backoff-cached', 10, 'https://api/x', { maxAge: 0 })
  await step('backoff-uncached', 10, 'https://api/y')
  await step('after-backoff-500', 7_300_000, 'https://api/y')
  await step('429-no-reset', 10, 'https://api/y')
  return { script: script.map((s) => ({ status: s.status, headers: s.headers ?? null, body: s.body ?? null })), calls, steps }
}
G('githubCache', await ghTrace())

const idA = bytes('idA', 16), idB = bytes('idB', 16), dest = bytes('dest', 16)
const pktCases = []
for (const [name, f] of [
  ['hello', { type: pk.TYPE.LINK_HELLO, id: idA, payload: bytes('p1', 40) }],
  ['ping', { type: pk.TYPE.PING, id: idA }],
  ['pong', { type: pk.TYPE.PONG, id: idB, ttl: 1, hops: 3 }],
  ['data', { type: pk.TYPE.DATA, id: idA, dest, payload: bytes('p2', 200), ttl: 8, hops: 0 }],
  ['ack', { type: pk.TYPE.ACK, id: idB, dest: idA, hops: 255 }],
  ['dead_end', { type: pk.TYPE.DEAD_END, id: idB, dest: idA, ttl: 0 }],
  ['discover', { type: pk.TYPE.DISCOVER, id: idA, payload: bytes('p3', 1) }],
  ['reply', { type: pk.TYPE.REPLY, id: idB, dest: idA, payload: bytes('p4', 33) }],
  ['app', { type: pk.TYPE.APP, id: idA, payload: bytes('p5', 1000) }],
  ['max', { type: pk.TYPE.DATA, id: idA, dest, payload: new Uint8Array(pk.MAX_PACKET - pk.HEADER) }],
]) {
  const e = pk.encodePacket(f)
  const d = pk.decodePacket(e)
  pktCases.push({ name, in: { type: f.type, ttl: f.ttl ?? null, hops: f.hops ?? null, id: hex(f.id), dest: f.dest ? hex(f.dest) : null, payload: f.payload ? hex(f.payload) : null }, encoded: e.length > 4096 ? { len: e.length, sha256: hex(sha256(e)) } : hex(e), decoded: { type: d.type, ttl: d.ttl, hops: d.hops, id: hex(d.id), dest: hex(d.dest), payload: d.payload.length > 4096 ? { len: d.payload.length } : hex(d.payload) } })
}
seed('newId')
const pBase = pk.encodePacket({ type: 10, id: idA, dest, payload: Uint8Array.of(1) })
const decBad = [new Uint8Array(0), pBase.slice(0, 35), (() => { const x = pBase.slice(); x[0] = 2; return x })(), (() => { const x = pBase.slice(); x[0] = 0; return x })(), new Uint8Array(65537).fill(1)].map((b) => ({ in: b.length > 4096 ? { len: b.length, first: b[0] } : hex(b), out: (() => { try { pk.decodePacket(b); return 'ok' } catch (e) { return { error: e.message } } })() }))
const encBad = [{ id: new Uint8Array(15) }, { dest: new Uint8Array(17) }, { payload: new Uint8Array(65501) }].map((f) => ({ in: Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v.length])), out: (() => { try { pk.encodePacket({ type: 10, id: idA, ...f }); return 'ok' } catch (e) { return { error: e.message } } })() }))
seed('newId')
const withDefaults = pk.encodePacket({ type: pk.TYPE.PING })
G('packet', {
  constants: { TYPE: pk.TYPE, TTL_DEFAULT: pk.TTL_DEFAULT, HEADER: pk.HEADER, MAX_PACKET: pk.MAX_PACKET },
  roundtrip: pktCases, decodeBad: decBad, encodeBad: encBad,
  defaults: { rngSeed: 'newId', encoded: hex(withDefaults), newId: (seed('newId'), hex(pk.newId())) },
})

const tagN = (n) => new Uint8Array(16).fill(n)
const dataP = (dst, ttl, id, payload = Uint8Array.of(1, 2, 3)) => pk.encodePacket({ type: pk.TYPE.DATA, dest: dst, ttl, id, payload })
const sim = (label, names, edges, script) => {
  seed('router:' + label)
  let clock = 1_700_000_000_000
  const ev = [], queue = [], routers = {}
  names.forEach((name, i) => {
    routers[name] = new Router({
      selfTag: tagN(i + 1),
      sendTo: (to, b) => { ev.push({ e: 'send', at: name, to, pkt: hex(b) }); queue.push(() => routers[to].onPacket(b, name)) },
      deliver: (b, from) => ev.push({ e: 'deliver', at: name, from, pkt: hex(b) }),
      now: () => clock,
    })
  })
  for (const [a, b] of edges) { routers[a].linkUp(b); routers[b].linkUp(a) }
  const run = () => { let n = 0; while (queue.length) { queue.shift()(); if (++n > 10000) throw new Error('loop') } }
  const ctx = { routers, ev, run, tagOf: (n) => tagN(names.indexOf(n) + 1), advance: (ms) => { clock += ms }, inject: (at, b, from) => { ev.push({ e: 'inject', at, from, pkt: hex(b) }); routers[at].onPacket(b, from) }, mark: (m) => ev.push({ e: 'mark', m }) }
  script(ctx)
  const snap = Object.fromEntries(names.map((n) => { const r = routers[n]; return [n, { links: r.neighbors(), routes: [...r.routes].map(([d, v]) => [d, v.n, v.t]), seen: [...r.seen].map(([k, t]) => [k, t]), reverse: [...r.reverse].map(([k, v]) => [k, v.prev, v.dest, v.pending, v.done, v.t]) }] }))
  return { label, names, selfTags: names.map((_, i) => hex(tagN(i + 1))), edges, events: ev, final: snap }
}
const lineN = (n) => [...'ABCDEF'].slice(0, n)
const lineE = (n) => n.slice(1).map((x, i) => [n[i], x])
const ids = (k) => bytes('rid:' + k, 16)
const scenarios = []
{
  const n = lineN(6)
  scenarios.push(sim('line6', n, lineE(n), (c) => {
    c.inject('A', dataP(c.tagOf('F'), 8, ids(1)), 'self'); c.run()
    c.mark('second data unicast'); c.inject('A', dataP(c.tagOf('F'), 8, ids(2)), 'self'); c.run()
    c.mark('absent recipient'); c.inject('A', dataP(tagN(99), 8, ids(3)), 'self'); c.run()
    c.mark('duplicate id'); c.inject('A', dataP(c.tagOf('F'), 8, ids(1)), 'self'); c.run()
    c.mark('linkDown C'); c.routers.C.linkDown('D'); c.routers.D.linkDown('C'); c.inject('A', dataP(c.tagOf('F'), 8, ids(4)), 'self'); c.run()
  }))
}
scenarios.push(sim('diamond', ['A', 'B', 'C', 'D'], [['A', 'B'], ['A', 'C'], ['B', 'D'], ['C', 'D'], ['B', 'C']], (c) => {
  c.inject('A', dataP(c.tagOf('D'), 8, ids(10)), 'self'); c.run()
  c.mark('again'); c.inject('A', dataP(c.tagOf('D'), 8, ids(11)), 'self'); c.run()
}))
{
  const n = Array.from({ length: 40 }, (_, i) => `n${i}`)
  const t = sim('line40-hops', n, lineE(n), (c) => { c.inject('n0', dataP(c.tagOf('n39'), 1, ids(20)), 'self'); c.run() })
  t.events = t.events.filter((e) => e.e === 'deliver' || e.e === 'mark' || e.e === 'inject')
  scenarios.push(t)
}
{
  const n = lineN(4)
  scenarios.push(sim('discover', n, [...lineE(n), ['A', 'D']], (c) => {
    for (const x of 'BCD') {
      const r = c.routers[x], orig = r.deliver
      r.deliver = (b, from) => {
        orig(b, from)
        const p = pk.decodePacket(b)
        if (p.type === pk.TYPE.DISCOVER) r.onPacket(pk.encodePacket({ type: pk.TYPE.REPLY, dest: p.id, id: bytes(`reply:${x}`, 16), payload: Uint8Array.of(x.charCodeAt(0)) }), 'self')
      }
    }
    c.inject('A', pk.encodePacket({ type: pk.TYPE.DISCOVER, id: ids(30) }), 'self'); c.run()
  }))
}
scenarios.push(sim('misc', ['A', 'B', 'C'], [['A', 'B'], ['B', 'C']], (c) => {
  c.mark('garbage'); c.routers.B.onPacket(new Uint8Array(10), 'A'); c.routers.B.onPacket(Uint8Array.of(9, ...new Array(40).fill(0)), 'A')
  c.mark('app'); c.inject('B', pk.encodePacket({ type: pk.TYPE.APP, id: ids(40), payload: Uint8Array.of(7) }), 'A')
  c.mark('discover from A'); c.inject('B', pk.encodePacket({ type: pk.TYPE.DISCOVER, id: ids(41) }), 'A'); c.run()
  c.mark('same discover again'); c.inject('B', pk.encodePacket({ type: pk.TYPE.DISCOVER, id: ids(41) }), 'A'); c.run()
  c.mark('ack unknown'); c.inject('B', pk.encodePacket({ type: pk.TYPE.ACK, id: ids(42), dest: ids(43) }), 'C'); c.run()
  c.mark('data to self from A'); c.inject('B', dataP(c.tagOf('B'), 8, ids(44)), 'A'); c.run()
  c.mark('data hops'); c.inject('B', pk.encodePacket({ type: pk.TYPE.DATA, id: ids(45), dest: tagN(77), hops: 255 }), 'A'); c.run()
  c.mark('expire'); c.advance(11 * 60e3); c.inject('B', dataP(c.tagOf('C'), 8, ids(46)), 'A'); c.run()
  c.mark('route expiry'); c.advance(11 * 60e3); c.inject('B', dataP(c.tagOf('C'), 8, ids(47)), 'A'); c.run()
  c.mark('no neighbours'); c.routers.B.linkDown('A'); c.routers.B.linkDown('C'); c.inject('B', dataP(tagN(55), 8, ids(48)), 'self')
}))
G('router', scenarios)

const sigA = createDevSignal({ get: () => bA, set: () => {} })
const sigB = createDevSignal({ get: () => bB, set: () => {} })
const ikA = (await sigA.signalInit()).ik, ikB = (await sigB.signalInit()).ik
const proofs = []
for (const [x, y, xi, yi] of [[sigA, ikB, ikA, ikB], [sigB, ikA, ikB, ikA]]) {
  const n = bytes('nonce:' + hex(xi).slice(0, 4), 16)
  const ct = sha256(xi).slice(0, 16), pt = sha256(yi).slice(0, 16)
  proofs.push({ ik: hex(xi), other: hex(yi), n: hex(n), challengerTag: hex(ct), proverTag: hex(pt), proof: hex(await x.signalProof(y, n, ct, pt)), safety: await x.signalSafetyNumber(y) })
}
const msgs = []
{
  const s = createDevSignal({ get: () => bA, set: () => {} })
  const tagB = await s.signalAddContact(bB)
  const sealed = await s.signalSeal(tagB, Uint8Array.of(1, 2, 3))
  const opened = await createDevSignal({ get: () => bB, set: () => {} }).signalOpen(sealed)
  msgs.push({ tag: tagB, sealed: hex(sealed), opened: { tag: opened.tag, ik: hex(opened.ik), plaintext: hex(opened.plaintext) } })
}
G('devSignal', { proofs, seal: msgs, safetySelf: await sigA.signalSafetyNumber(ikA) })

G('state', { defaults: JSON.parse(JSON.stringify(createState())) })
G('findHashPrefix', { prefix: 'ripplo-find-v1\u0000', hashBytes: 8 })

const dir = dirname(fileURLToPath(import.meta.url))
const target = resolve(dir, '../test/vectors/js_vectors.json')
mkdirSync(dirname(target), { recursive: true })
writeFileSync(target, JSON.stringify(out, null, 1) + '\n')
