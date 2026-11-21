import { describe, it, expect } from 'vitest'
import QRCode from 'qrcode'
import jsQR from 'jsqr'
import { encodeCard, encodeLink, parseLink, checkCard, deriveIds, formatId } from '../src/crypto/identity.js'
import { createDevSignal } from '../src/mesh/devSignal.js'
import { encryptFile, decryptFile, chunkCount, chunkPayload, parseChunk, CHUNK } from '../src/crypto/attachment.js'
import { b64url, utf8, concat, random, base32 } from '../src/lib/bytes.js'
import { sha256 } from '@noble/hashes/sha2.js'

const makeLink = async (name = 'Alice') => {
  const { bundle, ik } = await createDevSignal().signalInit()
  const card = encodeCard(name, bundle)
  return { card, ik, link: encodeLink(card) }
}
const code = (fn) => { try { fn(); return null } catch (e) { return e.code } }
const relink = (card) => `ripplo://add/${b64url(card)}.${b64url(sha256(card).slice(0, 6))}`

describe('bytes', () => {
  it('base32 of 10 bytes is 16 chars', () => {
    expect(base32(random(10))).toHaveLength(16)
    expect(base32(new Uint8Array(10))).toBe('0'.repeat(16))
  })
})

describe('invite link', () => {
  it('roundtrips, tolerates wrapping, rejects tampering', async () => {
    const { card, ik, link } = await makeLink()
    const v = parseLink(link)
    expect(v.card).toEqual(card)
    expect(v.name).toBe('Alice')
    expect(v.ik).toEqual(ik)
    expect(v.id).toBe(deriveIds(ik).ripploId)
    expect(formatId(v.id)).toMatch(/^\w{4}-\w{4}-\w{4}-\w{4}$/)
    expect(parseLink(`  ${link.slice(0, 30)}\n ${link.slice(30)} \n`).id).toBe(v.id)
    expect(parseLink(`join me: https://ripplo.app/add?x=${link} thanks`).id).toBe(v.id)
    const [head, sum] = link.split('.')
    expect(code(() => parseLink(`${head}.${sum.slice(0, 7)}${sum[7] === 'A' ? 'B' : 'A'}`))).toBe('bad_checksum')
    const flipped = head.slice(0, 40) + (head[40] === 'A' ? 'B' : 'A') + head.slice(41)
    expect(code(() => parseLink(`${flipped}.${sum}`))).toBe('bad_checksum')
    expect(code(() => parseLink('hello'))).toBe('bad_link')
  })

  it('rejects tampered or short cards', async () => {
    const { card } = await makeLink()
    const nl = card[1]
    const bad = (c) => code(() => parseLink(relink(c)))
    expect(bad(card.slice(0, 100))).toBe('bad_link')
    expect(bad(card.slice(0, card.length - 1))).toBe('bad_link')
    expect(bad(concat(card, new Uint8Array(1)))).toBe('bad_link')
    const v = (i, x) => { const c = card.slice(); c[i] = x; return c }
    expect(bad(v(0, 1))).toBe('bad_link')
    expect(bad(v(1, 0))).toBe('bad_link')
    expect(bad(v(1, 121))).toBe('bad_link')
    expect(bad(v(2 + nl, 1))).toBe('bad_link')
    expect(bad(v(2 + nl + 5, 4))).toBe('bad_link')
    expect(bad(concat(new Uint8Array([2, 2]), utf8('  '), card.subarray(2 + nl)))).toBe('bad_link')
    expect(code(() => checkCard(new Uint8Array(0)))).toBe('bad_link')
  })

  it('renders as a QR code that jsQR decodes', async () => {
    const { link } = await makeLink('A'.repeat(40))
    expect(link.length).toBeGreaterThan(2300)
    const { modules } = QRCode.create(link, { errorCorrectionLevel: 'L' })
    const px = 4, quiet = 4, n = modules.size, size = (n + quiet * 2) * px
    const rgba = new Uint8ClampedArray(size * size * 4).fill(255)
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const mx = Math.floor(x / px) - quiet, my = Math.floor(y / px) - quiet
        if (mx >= 0 && my >= 0 && mx < n && my < n && modules.get(my, mx)) {
          const o = (y * size + x) * 4
          rgba[o] = rgba[o + 1] = rgba[o + 2] = 0
        }
      }
    }
    expect(jsQR(rgba, size, size)?.data).toBe(link)
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
