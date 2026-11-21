import { describe, expect, it } from 'vitest'
import { HEADER, TYPE, decodePacket, encodePacket, newId } from '../src/mesh/packet.js'
import { Router } from '../src/mesh/router.js'

const tag = (n) => new Uint8Array(16).fill(n)

function net(names, edges) {
  const queue = [], sends = [], inbox = {}
  const routers = {}
  names.forEach((name, i) => {
    inbox[name] = []
    routers[name] = new Router({
      selfTag: tag(i + 1),
      sendTo: (to, bytes) => { sends.push({ from: name, to, p: decodePacket(bytes) }); queue.push(() => routers[to].onPacket(bytes, name)) },
      deliver: (bytes, from) => inbox[name].push({ p: decodePacket(bytes), from }),
    })
  })
  for (const [a, b] of edges) { routers[a].linkUp(b); routers[b].linkUp(a) }
  const run = () => { let n = 0; while (queue.length) { queue.shift()(); if (++n > 10000) throw new Error('loop') } }
  const tagOf = (name) => tag(names.indexOf(name) + 1)
  const ofType = (name, type) => inbox[name].filter((x) => x.p.type === type)
  return { routers, sends, inbox, run, tagOf, ofType }
}

const line = (n) => [...'ABCDEF'].slice(0, n)
const lineEdges = (names) => names.slice(1).map((x, i) => [names[i], x])
const data = (dest, ttl) => encodePacket({ type: TYPE.DATA, dest, ttl, payload: Uint8Array.of(1, 2, 3) })

describe('router', () => {
  it('(a) line: delivered once, ACK hops=5, routes learned, second DATA unicast', () => {
    const names = line(6), t = net(names, lineEdges(names))
    t.routers.A.onPacket(data(t.tagOf('F')), 'self'); t.run()
    expect(t.ofType('F', TYPE.DATA)).toHaveLength(1)
    for (const n of 'ABCDE') expect(t.ofType(n, TYPE.DATA)).toHaveLength(0)
    const acks = t.ofType('A', TYPE.ACK)
    expect(acks).toHaveLength(1)
    expect(acks[0].p.hops).toBe(5)
    expect(t.routers.B.routes.size).toBe(1)
    t.sends.length = 0
    t.routers.A.onPacket(data(t.tagOf('F')), 'self'); t.run()
    expect(t.ofType('F', TYPE.DATA)).toHaveLength(2)
    expect(t.sends.filter((s) => s.p.type === TYPE.DATA)).toHaveLength(5)
  })

  it('(b) absent recipient: one aggregated DEAD_END, bounded sends', () => {
    const names = line(6), t = net(names, lineEdges(names))
    t.routers.A.onPacket(data(tag(99)), 'self'); t.run()
    expect(t.ofType('A', TYPE.DEAD_END)).toHaveLength(1)
    expect(t.ofType('A', TYPE.ACK)).toHaveLength(0)
    expect(t.sends.length).toBe(10)
  })

  it('(c) diamond: duplicate gets DEAD_END, A still gets ACK and no DEAD_END', () => {
    const t = net(['A', 'B', 'C', 'D'], [['A', 'B'], ['A', 'C'], ['B', 'D'], ['C', 'D'], ['B', 'C']])
    t.routers.A.onPacket(data(t.tagOf('D')), 'self'); t.run()
    expect(t.ofType('D', TYPE.DATA)).toHaveLength(1)
    expect(t.ofType('A', TYPE.ACK)).toHaveLength(1)
    expect(t.ofType('A', TYPE.DEAD_END)).toHaveLength(0)
    expect(t.sends.some((s) => s.p.type === TYPE.DEAD_END)).toBe(true)
  })

  it('(d) no hop limit: line of 40 with ttl field 1 still delivers, hops saturate safely', () => {
    const names = Array.from({ length: 40 }, (_, i) => `n${i}`), t = net(names, lineEdges(names))
    t.routers.n0.onPacket(data(t.tagOf('n39'), 1), 'self'); t.run()
    expect(t.ofType('n39', TYPE.DATA)).toHaveLength(1)
    expect(t.ofType('n0', TYPE.ACK)[0].p.hops).toBe(39)
    expect(t.ofType('n0', TYPE.DEAD_END)).toHaveLength(0)
  })

  it('(e) DISCOVER floods, each other node delivers once, REPLYs reach origin', () => {
    const names = line(4), t = net(names, [...lineEdges(names), ['A', 'D']])
    for (const n of 'BCD') {
      const r = t.routers[n], orig = r.deliver
      r.deliver = (bytes, from) => {
        orig(bytes, from)
        const p = decodePacket(bytes)
        if (p.type === TYPE.DISCOVER) r.onPacket(encodePacket({ type: TYPE.REPLY, dest: p.id, payload: Uint8Array.of(n.charCodeAt(0)) }), 'self')
      }
    }
    t.routers.A.onPacket(encodePacket({ type: TYPE.DISCOVER }), 'self'); t.run()
    for (const n of 'BCD') expect(t.ofType(n, TYPE.DISCOVER)).toHaveLength(1)
    expect(t.ofType('A', TYPE.DISCOVER)).toHaveLength(0)
    expect(t.ofType('A', TYPE.REPLY).map((x) => x.p.payload[0]).sort()).toEqual([66, 67, 68])
  })

  it('(f) packet roundtrip and bad input', () => {
    const id = newId(), p = encodePacket({ type: TYPE.DATA, ttl: 5, hops: 2, id, dest: tag(7), payload: Uint8Array.of(9, 8) })
    const d = decodePacket(p)
    expect([d.type, d.ttl, d.hops]).toEqual([10, 5, 2])
    expect(d.id).toEqual(id); expect(d.dest).toEqual(tag(7)); expect(d.payload).toEqual(Uint8Array.of(9, 8))
    const bad = p.slice(); bad[0] = 2
    expect(() => decodePacket(bad)).toThrow()
    expect(() => decodePacket(p.slice(0, HEADER - 1))).toThrow()
    expect(() => encodePacket({ type: 10, payload: new Uint8Array(70000) })).toThrow()
  })
})
