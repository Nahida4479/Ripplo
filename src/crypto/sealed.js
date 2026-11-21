import { x25519 } from '@noble/curves/ed25519.js'
import { hkdf } from '@noble/hashes/hkdf.js'
import { sha256 } from '@noble/hashes/sha2.js'
import { concat, random, utf8 } from '../lib/bytes.js'

const INFO = utf8('ripplo-sealed-v1')

async function aesKey(ephPriv, recipientPub32, recipientTag, usage) {
  const raw = hkdf(sha256, x25519.getSharedSecret(ephPriv, recipientPub32), recipientTag, INFO, 32)
  return crypto.subtle.importKey('raw', raw, 'AES-GCM', false, [usage])
}

export async function seal(recipientIk33, recipientTag, inner) {
  const eph = x25519.keygen()
  const key = await aesKey(eph.secretKey, recipientIk33.subarray(1), recipientTag, 'encrypt')
  const nonce = random(12)
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, inner))
  return concat(new Uint8Array([1]), eph.publicKey, nonce, ct)
}

export async function unseal(identityPriv32, ownTag, sealed) {
  if (sealed.length < 1 + 32 + 12 + 16 || sealed[0] !== 1) throw new Error('bad sealed message')
  const key = await aesKey(identityPriv32, sealed.subarray(1, 33), ownTag, 'decrypt')
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: sealed.subarray(33, 45) }, key, sealed.subarray(45)))
}
