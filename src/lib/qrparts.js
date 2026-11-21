import { sha256 } from '@noble/hashes/sha2.js'
import { b64url, utf8 } from './bytes.js'

export const PART_SIZE = 420
const MAX_PARTS = 20
const MAX_SETS = 4
const RE = /^ripplo:\/\/p\/([A-Za-z0-9_-]{8})\.(\d{1,2})\.(\d{1,2})\.(.+)$/s

const setId = (link) => b64url(sha256(utf8(link)).slice(0, 6))

export function splitLink(link) {
  const total = Math.ceil(link.length / PART_SIZE)
  const id = setId(link)
  return Array.from({ length: total }, (_, i) => `ripplo://p/${id}.${i + 1}.${total}.${link.slice(i * PART_SIZE, (i + 1) * PART_SIZE)}`)
}

export function createAssembler() {
  const sets = new Map()
  return {
    add(text) {
      const m = RE.exec(String(text).trim())
      if (!m) return null
      const id = m[1]
      const index = Number(m[2])
      const total = Number(m[3])
      const data = m[4]
      if (total < 2 || total > MAX_PARTS || index < 1 || index > total || data.length > PART_SIZE) return { ignored: true }
      let set = sets.get(id)
      if (!set || set.total !== total) {
        set = { total, parts: new Map() }
        sets.set(id, set)
        if (sets.size > MAX_SETS) sets.delete(sets.keys().next().value)
      }
      set.parts.set(index, data)
      if (set.parts.size < total) return { have: set.parts.size, total }
      sets.delete(id)
      const link = Array.from({ length: total }, (_, k) => set.parts.get(k + 1)).join('')
      return setId(link) === id ? { link } : { bad: true }
    },
  }
}
