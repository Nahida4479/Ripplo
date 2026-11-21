const BACKOFF_KEY = 'gh:backoff'
const FALLBACK_BACKOFF = 15 * 60e3
const MIN_BACKOFF = 60e3

export function createGithub({ fetchFn = (...a) => fetch(...a), storage, now = () => Date.now(), ttl = 30 * 60e3 }) {
  const read = (k) => { try { return JSON.parse(storage.getItem(k)) } catch { return null } }
  const write = (k, v) => { try { storage.setItem(k, JSON.stringify(v)) } catch {} }
  const rate = (until) => Object.assign(new Error('rate'), { code: 'rate', until })

  return async function get(url, { maxAge = ttl } = {}) {
    const key = 'gh:' + url
    const cached = read(key)
    if (cached && now() - cached.at < maxAge) return cached.body
    const until = Number(storage.getItem(BACKOFF_KEY) || 0)
    if (until > now()) {
      if (cached) return cached.body
      throw rate(until)
    }
    const headers = { Accept: 'application/vnd.github+json', ...(cached?.etag && { 'If-None-Match': cached.etag }) }
    const r = await fetchFn(url, { headers })
    if (r.status === 304 && cached) {
      write(key, { ...cached, at: now() })
      return cached.body
    }
    if (r.status === 403 || r.status === 429) {
      const reset = Number(r.headers.get('x-ratelimit-reset')) * 1000
      const wait = Math.max(Number.isFinite(reset) && reset > 0 ? reset : now() + FALLBACK_BACKOFF, now() + MIN_BACKOFF)
      try { storage.setItem(BACKOFF_KEY, String(wait)) } catch {}
      if (cached) return cached.body
      throw rate(wait)
    }
    if (!r.ok) throw new Error(String(r.status))
    const body = await r.json()
    write(key, { etag: r.headers.get('etag'), body, at: now() })
    return body
  }
}
