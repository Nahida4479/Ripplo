import { x25519 } from '@noble/curves/ed25519.js'
import { hkdf } from '@noble/hashes/hkdf.js'
import { hmac } from '@noble/hashes/hmac.js'
import { sha256, sha512 } from '@noble/hashes/sha2.js'
import { concat, utf8, equal } from '../lib/bytes.js'

function digits(ik33, ripploId) {
  const id = utf8(ripploId)
  let h = concat(new Uint8Array([0, 0]), ik33, id)
  for (let i = 0; i < 5200; i++) h = sha512(concat(h, ik33))
  let out = ''
  for (let i = 0; i < 30; i += 5) {
    const n = h.slice(i, i + 5).reduce((a, b) => a * 256 + b, 0)
    out += String(n % 100000).padStart(5, '0')
  }
  return out
}

export function safetyNumber(myIk, myId, theirIk, theirId) {
  return [digits(myIk, myId), digits(theirIk, theirId)].sort().join('')
}

const INFO = utf8('ripplo-proof-v1')
export function proofMac(myPriv32, otherIk33, n, aTag, bTag) {
  const k = hkdf(sha256, x25519.getSharedSecret(myPriv32, otherIk33.subarray(1)), n, INFO, 32)
  return hmac(sha256, k, concat(INFO, n, aTag, bTag))
}
export const proofValid = (mac, expected) => equal(mac, expected)
