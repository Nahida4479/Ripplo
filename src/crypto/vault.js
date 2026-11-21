import { concat, random } from '../lib/bytes.js'

export async function createVault(mesh) {
  const { key: raw, insecure } = await mesh.getDbKey()
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt'])
  return {
    insecure: !!insecure,
    async seal(bytes, aad) {
      const nonce = random(12)
      const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: aad }, key, bytes))
      return concat(nonce, ct)
    },
    async open(sealed, aad) {
      const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: sealed.subarray(0, 12), additionalData: aad }, key, sealed.subarray(12))
      return new Uint8Array(pt)
    },
  }
}
