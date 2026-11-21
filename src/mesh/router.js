// Reference router: mirrors docs/ARCHITECTURE.md §3.1 (Kotlin and Swift ports follow this file).
import { TYPE, TTL_DEFAULT, decodePacket, encodePacket, newId } from './packet.js'

const SELF = 'self'
const EXPIRY_MS = 10 * 60 * 1000
const SEEN_CAP = 20000
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
const unhex = (s) => Uint8Array.from(s.match(/../g), (x) => parseInt(x, 16))

export class Router {
  constructor({ selfTag, sendTo, deliver, now = Date.now }) {
    this.selfHex = hex(selfTag)
    this.sendTo = sendTo
    this.deliver = deliver
    this.now = now
    this.seen = new Map()     // `${type}:${idHex}` -> time (insertion order == time order)
    this.reverse = new Map()  // idHex -> { prev, dest, pending, done, t }
    this.routes = new Map()   // destTagHex -> { n: neighbor, t }
    this.links = new Set()
  }

  neighbors() { return [...this.links] }
  linkUp(n) { this.links.add(n) }
  linkDown(n) {
    this.links.delete(n)
    for (const [d, r] of this.routes) if (r.n === n) this.routes.delete(d)
  }

  onPacket(bytes, from) {
    let p
    try { p = decodePacket(bytes) } catch { return }
    this.expire()
    const id = hex(p.id), dest = hex(p.dest)
    switch (p.type) {
      case TYPE.APP:
        this.deliver(bytes, from)
        break
      case TYPE.DATA:
      case TYPE.DISCOVER: {
        if (this.isSeen(p, id)) {
          if (from !== SELF) this.sendDeadEnd(from, id)
          return
        }
        this.markSeen(p, id)
        const r = { prev: from, dest, pending: 0, done: false, t: this.now() }
        this.reverse.set(id, r)
        if (p.type === TYPE.DATA && dest === this.selfHex) {
          if (from !== SELF) this.send(from, { type: TYPE.ACK, dest: p.id })
          this.deliver(bytes, from)
          return
        }
        if (p.type === TYPE.DISCOVER && from !== SELF) this.deliver(bytes, from)
        if (from !== SELF && p.ttl <= 1) { this.sendDeadEnd(from, id); return }
        const q = from === SELF ? bytes : encodePacket({ ...p, ttl: Math.min(p.ttl, TTL_DEFAULT) - 1, hops: Math.min(p.hops + 1, 255) }) // clamp: a hostile neighbor can't widen the flood
        const route = p.type === TYPE.DATA ? this.routes.get(dest) : null
        const targets = route && this.links.has(route.n) && route.n !== from
          ? [route.n]
          : this.neighbors().filter((n) => n !== from)
        if (!targets.length) { this.deadEnd(id); return }
        r.pending = targets.length
        for (const n of targets) this.sendTo(n, q)
        break
      }
      case TYPE.ACK:
      case TYPE.REPLY: {
        if (this.isSeen(p, id)) return
        this.markSeen(p, id)
        const r = this.reverse.get(dest)
        if (!r) return
        if (p.type === TYPE.ACK) {
          if (from !== SELF) this.routes.set(r.dest, { n: from, t: this.now() })
          r.done = true
        }
        // hops counts links traversed, so a direct neighbour is 1 (ARCHITECTURE leaves this open)
        if (r.prev === SELF) this.deliver(encodePacket({ ...p, hops: Math.min(p.hops + 1, 255) }), SELF)
        else this.sendTo(r.prev, encodePacket({ ...p, hops: Math.min(p.hops + 1, 255) }))
        break
      }
      case TYPE.DEAD_END: {
        if (this.isSeen(p, id)) return
        this.markSeen(p, id)
        const r = this.reverse.get(dest)
        if (!r || r.done) return
        if (--r.pending <= 0) this.deadEnd(dest)
        break
      }
    }
  }

  deadEnd(id) {
    const r = this.reverse.get(id)
    r.done = true
    if (r.prev === SELF) this.deliver(encodePacket({ type: TYPE.DEAD_END, dest: unhex(id) }), SELF)
    else this.sendDeadEnd(r.prev, id)
  }

  sendDeadEnd(to, id) { this.send(to, { type: TYPE.DEAD_END, dest: unhex(id) }) }
  send(to, fields) { this.sendTo(to, encodePacket({ id: newId(), ...fields })) }

  isSeen(p, id) { return this.seen.has(`${p.type}:${id}`) }
  markSeen(p, id) {
    this.seen.set(`${p.type}:${id}`, this.now())
    if (this.seen.size > SEEN_CAP) this.seen.delete(this.seen.keys().next().value)
  }

  expire() {
    const cutoff = this.now() - EXPIRY_MS
    for (const m of [this.seen, this.reverse]) {
      for (const [k, v] of m) {
        if ((v.t ?? v) > cutoff) break
        m.delete(k)
      }
    }
    for (const [k, v] of this.routes) if (v.t <= cutoff) this.routes.delete(k)
  }
}
