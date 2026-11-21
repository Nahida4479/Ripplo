import { sha256, sha512 } from '@noble/hashes/sha2.js'
import { hmac } from '@noble/hashes/hmac.js'
import { concat, random, hex } from '../lib/bytes.js'

const BUNDLE = 1776
const MARK = 0xee
const tagOf = (ik) => hex(sha256(ik).slice(0, 16))
const sorted = (a, b) => (hex(a) <= hex(b) ? concat(a, b) : concat(b, a))

export function createDevSignal(store = null) {
  const saved = store?.get()
  const bundle = saved || random(BUNDLE)
  if (!saved) {
    bundle[0] = 2
    bundle.set(concat(new Uint8Array([5]), random(32)), 5)
    store?.set(bundle)
  }
  const ik = bundle.slice(5, 38)
  const known = new Map()
  const bad = (code) => Object.assign(new Error(code), { code })

  return {
    async signalInit() { return { bundle, ik } },
    async signalAddContact(b) {
      if (b.length !== BUNDLE || b[0] !== 2 || b[5] !== 5) throw bad('bad_bundle')
      const key = b.slice(5, 38)
      known.set(tagOf(key), key)
      return tagOf(key)
    },
    async signalSeal(tag, plaintext) {
      if (!known.has(tag)) throw bad('no_session')
      return concat(new Uint8Array([MARK]), ik, plaintext)
    },
    async signalOpen(payload) {
      if (payload.length < 34 || payload[0] !== MARK || payload[1] !== 5) throw bad('bad_message')
      const key = payload.slice(1, 34)
      known.set(tagOf(key), key)
      return { tag: tagOf(key), ik: key, plaintext: payload.slice(34) }
    },
    async signalProof(other, n, challengerTag, proverTag) {
      return hmac(sha256, sha256(sorted(ik, other)), concat(n, challengerTag, proverTag))
    },
    async signalSafetyNumber(other) {
      const h = sha512(sorted(ik, other))
      let out = ''
      for (let i = 0; i < 60; i += 5) out += String(h.slice(i, i + 5).reduce((a, b) => a * 256 + b, 0) % 100000).padStart(5, '0')
      return out
    },
    async signalForget(tag) { known.delete(tag) },
  }
}
