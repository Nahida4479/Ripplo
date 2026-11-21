import { concat, random, u32, readU32 } from '../lib/bytes.js'
import { sha256 } from '@noble/hashes/sha2.js'

export const CHUNK = 32 * 1024
const aes = (key, usage) => crypto.subtle.importKey('raw', key, 'AES-GCM', false, [usage])

export async function encryptFile(bytes) {
  const key = random(32), nonce = random(12)
  const ct = concat(nonce, new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, await aes(key, 'encrypt'), bytes)))
  return { ct, key, sha256: sha256(ct) }
}

export async function decryptFile(ct, key) {
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: ct.subarray(0, 12) }, await aes(key, 'decrypt'), ct.subarray(12)))
}

export const chunkCount = (ct) => Math.ceil(ct.length / CHUNK)

export const chunkPayload = (attId, ct, index, total) =>
  concat(new Uint8Array([2]), attId, u32(index), u32(total), ct.subarray(index * CHUNK, (index + 1) * CHUNK))

export function parseChunk(payload) {
  if (payload.length < 25 || payload[0] !== 2) throw new Error('bad chunk')
  return { attId: payload.slice(1, 17), index: readU32(payload, 17), total: readU32(payload, 21), bytes: payload.slice(25) }
}
