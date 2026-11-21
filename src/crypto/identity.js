import { KeyHelper } from '@privacyresearch/libsignal-protocol-typescript'
import { sha256 } from '@noble/hashes/sha2.js'
import { b64, unb64, b64url, unb64url, utf8, unutf8, base32, equal } from '../lib/bytes.js'

export class RipploError extends Error {
  constructor(code, message = code) { super(message); this.code = code }
}

const MAX_NAME = 40
const BAD_CHARS = /[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g
export const cleanName = (s) => String(s ?? '').replace(BAD_CHARS, '').trim().slice(0, MAX_NAME)

export function deriveIds(ik33) {
  const tag = sha256(ik33).slice(0, 16)
  return { tag, ripploId: base32(tag.slice(0, 10)) }
}
export const formatId = (id) => id.match(/.{4}/g).join('-')

const isKey33 = (b) => b.length === 33 && b[0] === 5

export async function createIdentity() {
  const kp = await KeyHelper.generateIdentityKeyPair()
  const spk = await KeyHelper.generateSignedPreKey(kp, 1)
  return {
    ik: { pub: new Uint8Array(kp.pubKey), priv: new Uint8Array(kp.privKey) },
    regId: KeyHelper.generateRegistrationId(),
    spk: { id: 1, pub: new Uint8Array(spk.keyPair.pubKey), priv: new Uint8Array(spk.keyPair.privKey), sig: new Uint8Array(spk.signature) },
  }
}

export function makeCard(identity, name) {
  return {
    v: 1, n: cleanName(name), ik: b64(identity.ik.pub), rid: identity.regId,
    spk: { id: identity.spk.id, pub: b64(identity.spk.pub), sig: b64(identity.spk.sig) },
  }
}

export function checkCard(card) {
  const bad = () => new RipploError('bad_link', 'invalid contact card')
  try {
    if (!card || card.v !== 1 || !Number.isInteger(card.rid) || card.rid < 0 || card.rid > 0x3fff) throw bad()
    const n = cleanName(card.n)
    const ik = unb64(card.ik), spkPub = unb64(card.spk.pub), sig = unb64(card.spk.sig)
    if (!n || !isKey33(ik) || !isKey33(spkPub) || sig.length !== 64 || !Number.isInteger(card.spk.id) || card.spk.id < 0) throw bad()
    const { tag, ripploId } = deriveIds(ik)
    return {
      card: { v: 1, n, ik: b64(ik), rid: card.rid, spk: { id: card.spk.id, pub: b64(spkPub), sig: b64(sig) } },
      id: ripploId, tag, ik,
    }
  } catch (e) {
    throw e instanceof RipploError ? e : bad()
  }
}

export function encodeLink(card) {
  const json = utf8(JSON.stringify(card))
  return `ripplo://add/${b64url(json)}.${b64url(sha256(json).slice(0, 6))}`
}

export function parseLink(text) {
  const m = /ripplo:\/\/add\/([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]{8})/.exec(String(text).replace(/\s+/g, ''))
  if (!m) throw new RipploError('bad_link', 'not a Ripplo link')
  let json, sum, card
  try {
    json = unb64url(m[1]); sum = unb64url(m[2])
    if (!equal(sha256(json).slice(0, 6), sum)) throw new RipploError('bad_checksum', 'link is corrupted')
    card = JSON.parse(unutf8(json))
  } catch (e) {
    throw e instanceof RipploError ? e : new RipploError('bad_link', 'not a Ripplo link')
  }
  return checkCard(card)
}
