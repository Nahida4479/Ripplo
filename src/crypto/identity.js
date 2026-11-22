import { sha256 } from '@noble/hashes/sha2.js'
import { b64url, unb64url, utf8, unutf8, base32, concat, equal } from '../lib/bytes.js'

export class RipploError extends Error {
  constructor(code, message = code) { super(message); this.code = code }
}

const MAX_NAME = 40
const MAX_NAME_BYTES = 120
const BUNDLE = 1776
const BAD_CHARS = /[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g
export const cleanName = (s) => String(s ?? '').replace(BAD_CHARS, '').trim().slice(0, MAX_NAME)

export function deriveIds(ik33) {
  const tag = sha256(ik33).slice(0, 16)
  return { tag, ripploId: base32(tag.slice(0, 10)) }
}
export const formatId = (id) => id.match(/.{4}/g).join('-')

export function encodeCard(name, bundle) {
  const n = utf8(cleanName(name))
  return concat(new Uint8Array([2, n.length]), n, bundle)
}

export function checkCard(card) {
  const bad = () => new RipploError('bad_link', 'invalid contact card')
  if (!(card instanceof Uint8Array) || card.length < 2 + BUNDLE || card[0] !== 2) throw bad()
  const len = card[1]
  if (len < 1 || len > MAX_NAME_BYTES || card.length !== 2 + len + BUNDLE) throw bad()
  const name = cleanName(unutf8(card.subarray(2, 2 + len)))
  const bundle = card.subarray(2 + len)
  if (!name || bundle[0] !== 2 || bundle[5] !== 5) throw bad()
  const ik = bundle.slice(5, 38)
  const { tag, ripploId } = deriveIds(ik)
  return { id: ripploId, tag, ik, name, bundle, card }
}

export function encodeLink(card, token) {
  return `ripplo://add/${b64url(card)}.${b64url(sha256(card).slice(0, 6))}${token ? '.' + b64url(token) : ''}`
}

const SITE = 'https://nahida4479.github.io/Ripplo'

export function webLink(link, lang) {
  const m = /^ripplo:\/\/add\/(.+)$/.exec(link)
  if (!m) throw new RipploError('bad_link', 'not a Ripplo link')
  return `${SITE}${lang === 'pl' ? '/pl' : ''}/add/#${m[1]}`
}

export function parseLink(text) {
  const m = /(?:ripplo:\/\/add\/|https:\/\/nahida4479\.github\.io\/Ripplo\/(?:pl\/)?add\/?#)([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]{8})(?:\.([A-Za-z0-9_-]{11}))?/.exec(String(text).replace(/\s+/g, ''))
  if (!m) throw new RipploError('bad_link', 'not a Ripplo link')
  let card
  try {
    card = unb64url(m[1])
    if (!equal(sha256(card).slice(0, 6), unb64url(m[2]))) throw new RipploError('bad_checksum', 'link is corrupted')
  } catch (e) {
    throw e instanceof RipploError ? e : new RipploError('bad_link', 'not a Ripplo link')
  }
  const v = checkCard(card)
  return m[3] ? { ...v, token: m[3] } : v
}
