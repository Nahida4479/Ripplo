const enc = new TextEncoder()
const dec = new TextDecoder()
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

export const utf8 = (s) => enc.encode(s)
export const unutf8 = (b) => dec.decode(b)
export function random(n) {
  const out = new Uint8Array(n)
  for (let i = 0; i < n; i += 65536) crypto.getRandomValues(out.subarray(i, i + 65536))
  return out
}

export function b64(bytes) {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}
export function unb64(s) {
  const bin = atob(s)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}
export const b64url = (bytes) => b64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
export function unb64url(s) {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new Error('bad base64url')
  return unb64(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4))
}

export const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
export function unhex(s) {
  if (!/^([0-9a-f]{2})*$/i.test(s)) throw new Error('bad hex')
  return Uint8Array.from(s.match(/../g) || [], (h) => parseInt(h, 16))
}

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}

export function equal(a, b) {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i]
  return d === 0
}

export const ab = (u8) => u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength)

export const u32 = (n) => new Uint8Array([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255])
export const readU32 = (b, o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0

export function base32(bytes) {
  let bits = 0, acc = 0, out = ''
  for (const b of bytes) {
    acc = (acc << 8) | b; bits += 8
    while (bits >= 5) { out += CROCKFORD[(acc >>> (bits - 5)) & 31]; bits -= 5 }
    acc &= (1 << bits) - 1
  }
  if (bits) out += CROCKFORD[(acc << (5 - bits)) & 31]
  return out
}
