import { b64, unb64, ab, equal } from '../lib/bytes.js'
import { deriveIds } from './identity.js'

const kp = (o) => ({ pubKey: ab(unb64(o.pub)), privKey: ab(unb64(o.priv)) })
const unkp = (k) => ({ pub: b64(new Uint8Array(k.pubKey)), priv: b64(new Uint8Array(k.privKey)) })
const nameOf = (addr) => String(addr).replace(/\.\d+$/, '')

export function createSignalStore(db) {
  let own = null
  const get = (k) => db.get('kv', k)
  const put = (k, v) => db.put('kv', k, v)

  return {
    async setLocal({ ik, regId, spk, name }) {
      await put('signal/identity', { ik: { pub: b64(ik.pub), priv: b64(ik.priv) }, regId, name, spk: { id: spk.id, pub: b64(spk.pub), priv: b64(spk.priv), sig: b64(spk.sig) } })
      own = null
    },
    async local() {
      return (own ??= await get('signal/identity'))
    },
    async getIdentityKeyPair() {
      const l = await this.local()
      return l && kp(l.ik)
    },
    async getLocalRegistrationId() { return (await this.local())?.regId },
    async isTrustedIdentity(identifier, identityKey) {
      const ik = new Uint8Array(identityKey)
      if (ik.length !== 33 || ik[0] !== 5 || deriveIds(ik).ripploId !== nameOf(identifier)) return false
      const known = await get(`signal/ik/${nameOf(identifier)}`)
      return !known || equal(unb64(known), ik)
    },
    async saveIdentity(addr, publicKey) {
      const name = nameOf(addr), v = b64(new Uint8Array(publicKey))
      const known = await get(`signal/ik/${name}`)
      await put(`signal/ik/${name}`, v)
      return !!known && known !== v
    },
    async loadIdentity(name) {
      const v = await get(`signal/ik/${name}`)
      return v && unb64(v)
    },
    async loadPreKey(id) {
      const v = await get(`signal/pre/${id}`)
      return v && kp(v)
    },
    storePreKey: (id, k) => put(`signal/pre/${id}`, unkp(k)),
    removePreKey: (id) => db.del('kv', `signal/pre/${id}`),
    async loadSignedPreKey(id) {
      const l = await this.local()
      if (!l || String(l.spk.id) !== String(id)) return undefined
      return kp(l.spk)
    },
    async storeSignedPreKey() {},
    async removeSignedPreKey() {},
    storeSession: (addr, rec) => put(`signal/session/${addr}`, { r: rec }),
    async loadSession(addr) { return (await get(`signal/session/${addr}`))?.r },
    async removeSession(addr) {
      await db.del('kv', `signal/session/${addr}`)
      await db.del('kv', `signal/ik/${nameOf(addr)}`)
    },
  }
}
