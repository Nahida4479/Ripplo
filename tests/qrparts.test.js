import { describe, it, expect } from 'vitest'
import QRCode from 'qrcode'
import { splitLink, createAssembler, PART_SIZE } from '../src/lib/qrparts.js'

const link = 'ripplo://add/' + Array.from({ length: 2400 }, (_, i) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'[(i * 7 + (i >> 3)) % 64]).join('') + '.abcdefgh.ABCDEFGHIJK'

describe('multi-frame QR', () => {
  it('splits a large link into small frames that each fit a modest QR version', () => {
    const parts = splitLink(link)
    expect(parts.length).toBeGreaterThan(3)
    for (const p of parts) {
      expect(p.length).toBeLessThanOrEqual(PART_SIZE + 40)
      expect(QRCode.create(p, { errorCorrectionLevel: 'L' }).version).toBeLessThanOrEqual(14)
    }
  })

  it('assembles frames in any order, with repeats and unrelated noise', () => {
    const parts = splitLink(link)
    const a = createAssembler()
    expect(a.add('hello')).toBeNull()
    expect(a.add('ripplo://add/xyz.abcdefgh')).toBeNull()
    const order = [...parts.keys()].sort(() => Math.random() - 0.5)
    let last
    for (const i of order) {
      last = a.add(parts[i])
      a.add(parts[i])
      if (i !== order[order.length - 1]) expect(last.have).toBeLessThan(parts.length)
    }
    expect(last.link).toBe(link)
  })

  it('rejects a set whose checksum does not match and malformed frames', () => {
    const parts = splitLink(link)
    const a = createAssembler()
    const tampered = parts.map((p, i) => (i === 1 ? p.slice(0, -1) + (p.endsWith('A') ? 'B' : 'A') : p))
    let r
    for (const p of tampered) r = a.add(p)
    expect(r.bad).toBe(true)
    expect(createAssembler().add('ripplo://p/abcdefgh.9.3.xx').ignored).toBe(true)
    expect(createAssembler().add('ripplo://p/abcdefgh.1.99.xx').ignored).toBe(true)
    expect(createAssembler().add('ripplo://p/abcdefgh.1.2.' + 'x'.repeat(PART_SIZE + 1)).ignored).toBe(true)
  })

  it('keeps two codes shown one after another apart', () => {
    const other = link.replace('add/A', 'add/B')
    const a = createAssembler()
    const p1 = splitLink(link), p2 = splitLink(other)
    a.add(p1[0]); a.add(p2[0])
    for (let i = 1; i < p1.length - 1; i++) a.add(p1[i])
    for (let i = 1; i < p2.length; i++) a.add(p2[i])
    expect(a.add(p1[p1.length - 1]).link).toBe(link)
  })
})
