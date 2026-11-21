import { describe, it, expect } from 'vitest'
import { createGithub } from '../src/lib/githubCache.js'

const store = () => {
  const m = new Map()
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) }
}
const res = (status, body, headers = {}) => ({
  status, ok: status >= 200 && status < 300, json: async () => body,
  headers: { get: (k) => headers[k.toLowerCase()] ?? null },
})

describe('github release cache', () => {
  it('serves a fresh answer from the cache without asking again', async () => {
    let calls = 0
    let t = 1000
    const get = createGithub({ storage: store(), now: () => t, fetchFn: async () => { calls++; return res(200, { n: 1 }, { etag: 'e1' }) } })
    expect(await get('u')).toEqual({ n: 1 })
    t += 60e3
    expect(await get('u')).toEqual({ n: 1 })
    expect(calls).toBe(1)
  })

  it('revalidates a stale answer with the etag and keeps it on 304', async () => {
    const seen = []
    let t = 1000
    const get = createGithub({ storage: store(), now: () => t, fetchFn: async (u, o) => {
      seen.push(o.headers['If-None-Match'])
      return seen.length === 1 ? res(200, { n: 1 }, { etag: 'e1' }) : res(304, null)
    } })
    await get('u')
    t += 31 * 60e3
    expect(await get('u')).toEqual({ n: 1 })
    expect(seen).toEqual([undefined, 'e1'])
  })

  it('stops asking after a 403 until the reset time and reports it', async () => {
    let calls = 0
    let t = 5_000_000
    const reset = Math.floor((t + 20 * 60e3) / 1000)
    const get = createGithub({ storage: store(), now: () => t, fetchFn: async () => { calls++; return res(403, {}, { 'x-ratelimit-reset': String(reset) }) } })
    await expect(get('u')).rejects.toMatchObject({ code: 'rate', until: reset * 1000 })
    await expect(get('u2')).rejects.toMatchObject({ code: 'rate' })
    expect(calls).toBe(1)
    t = reset * 1000 + 1
    await expect(get('u')).rejects.toMatchObject({ code: 'rate' })
    expect(calls).toBe(2)
  })

  it('falls back to the cached answer when limited, and reports other errors as their status', async () => {
    let t = 1000
    let mode = 'ok'
    const get = createGithub({ storage: store(), now: () => t, fetchFn: async () => (mode === 'ok' ? res(200, { n: 1 }) : mode === 'limit' ? res(403, {}) : res(500, {})) })
    await get('u')
    t += 40 * 60e3
    mode = 'limit'
    expect(await get('u')).toEqual({ n: 1 })
    const other = createGithub({ storage: store(), fetchFn: async () => res(500, {}) })
    await expect(other('x')).rejects.toThrow('500')
  })

  it('works without usable storage', async () => {
    const broken = { getItem() { throw new Error('x') }, setItem() { throw new Error('x') } }
    const get = createGithub({ storage: Object.assign(broken, { getItem: () => null }), fetchFn: async () => res(200, { ok: 1 }) })
    expect(await get('u')).toEqual({ ok: 1 })
  })
})
