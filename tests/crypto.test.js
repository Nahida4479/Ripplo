import { describe, it, expect } from 'vitest'
import { x25519 } from '@noble/curves/ed25519.js'
import { seal, unseal } from '../src/crypto/sealed.js'
import { createIdentity, makeCard, encodeLink, parseLink, deriveIds, formatId } from '../src/crypto/identity.js'
import { safetyNumber, proofMac } from '../src/crypto/safety.js'
import { encryptFile, decryptFile, chunkCount, chunkPayload, parseChunk, CHUNK } from '../src/crypto/attachment.js'
import { b64, b64url, utf8, unutf8, concat, random, base32 } from '../src/lib/bytes.js'
import { sha256 } from '@noble/hashes/sha2.js'

describe('bytes', () => {
  it('base32 of 10 bytes is 16 chars', () => {
    expect(base32(random(10))).toHaveLength(16)
    expect(base32(new Uint8Array(10))).toBe('0'.repeat(16))
  })
})

describe('sealed', () => {
  it('roundtrips and fails with a wrong key', async () => {
    const id = await createIdentity()
    const { tag } = deriveIds(id.ik.pub)
    const s = await seal(id.ik.pub, tag, utf8('hello'))
    expect(s[0]).toBe(1)
    expect(unutf8(await unseal(id.ik.priv, tag, s))).toBe('hello')
    const other = await createIdentity()
    await expect(unseal(other.ik.priv, tag, s)).rejects.toThrow()
    s[s.length - 1] ^= 1
    await expect(unseal(id.ik.priv, tag, s)).rejects.toThrow()
    expect(x25519.getSharedSecret).toBeTypeOf('function')
  })
})

describe('invite link', () => {
  it('roundtrips, tolerates wrapping, rejects tampering', async () => {
    const id = await createIdentity()
    const card = makeCard(id, 'Alice')
    const link = encodeLink(card)
    const v = parseLink(link)
    expect(v.card).toEqual(card)
    expect(v.id).toBe(deriveIds(id.ik.pub).ripploId)
    expect(formatId(v.id)).toMatch(/^\w{4}-\w{4}-\w{4}-\w{4}$/)
    expect(parseLink(`  ${link.slice(0, 30)}\n ${link.slice(30)} \n`).id).toBe(v.id)
    expect(parseLink(`join me: https://ripplo.app/add?x=${link} thanks`).id).toBe(v.id)
    const bad = (s) => { try { parseLink(s); return null } catch (e) { return e.code } }
    const [head, sum] = link.split('.')
    expect(bad(`${head}.${sum.slice(0, 7)}A`)).toBe('bad_checksum')
    const flipped = head.slice(0, 40) + (head[40] === 'A' ? 'B' : 'A') + head.slice(41)
    expect(bad(`${flipped}.${sum}`)).toBe('bad_checksum')
    expect(bad('hello')).toBe('bad_link')
    const forge = (c) => {
      const j = utf8(JSON.stringify(c))
      return `ripplo://add/${b64url(j)}.${b64url(sha256(j).slice(0, 6))}`
    }
    const ik = new Uint8Array(33).fill(7)
    expect(bad(forge({ ...card, ik: b64(ik) }))).toBe('bad_link')
    expect(bad(forge({ ...card, ik: b64(ik.slice(0, 32)) }))).toBe('bad_link')
    expect(bad(forge({ ...card, n: '  ' }))).toBe('bad_link')
  })
})

describe('safety', () => {
  it('safety number matches on both sides and has 60 digits', async () => {
    const a = await createIdentity(), b = await createIdentity()
    const ia = deriveIds(a.ik.pub).ripploId, ib = deriveIds(b.ik.pub).ripploId
    const n1 = safetyNumber(a.ik.pub, ia, b.ik.pub, ib)
    expect(n1).toMatch(/^\d{60}$/)
    expect(safetyNumber(b.ik.pub, ib, a.ik.pub, ia)).toBe(n1)
    const c = await createIdentity()
    expect(safetyNumber(a.ik.pub, ia, c.ik.pub, deriveIds(c.ik.pub).ripploId)).not.toBe(n1)
  })
  it('proof macs agree between holder of either private key only', async () => {
    const a = await createIdentity(), b = await createIdentity(), m = await createIdentity()
    const ta = deriveIds(a.ik.pub).tag, tb = deriveIds(b.ik.pub).tag, n = random(32)
    const fromB = proofMac(b.ik.priv, a.ik.pub, n, ta, tb)
    expect(proofMac(a.ik.priv, b.ik.pub, n, ta, tb)).toEqual(fromB)
    expect(proofMac(m.ik.priv, a.ik.pub, n, ta, tb)).not.toEqual(fromB)
  })
})

describe('attachment', () => {
  it('encrypts, chunks and decrypts 100 KB', async () => {
    const file = random(100 * 1024)
    const { ct, key, sha256: h } = await encryptFile(file)
    expect(h).toEqual(sha256(ct))
    const total = chunkCount(ct)
    expect(total).toBe(Math.ceil((100 * 1024 + 28) / CHUNK))
    const attId = random(16)
    const parts = Array.from({ length: total }, (_, i) => parseChunk(chunkPayload(attId, ct, i, total)))
    expect(parts.every((p, i) => p.index === i && p.total === total)).toBe(true)
    const joined = concat(...parts.map((p) => p.bytes))
    expect(await decryptFile(joined, key)).toEqual(file)
    joined[40] ^= 1
    await expect(decryptFile(joined, key)).rejects.toThrow()
  })
})
