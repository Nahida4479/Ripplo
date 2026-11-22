const REPO = 'Nahida4479/Ripplo'
const root = document.documentElement
const $ = (s, r = document) => r.querySelector(s)
const $$ = (s, r = document) => [...r.querySelectorAll(s)]
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches
const nf = new Intl.NumberFormat(root.lang)
const L = root.dataset
const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
const os = isIOS ? 'ipa' : 'apk'

const slim = r => {
  const assets = {}
  for (const a of r.assets) {
    const kind = a.name.endsWith('.apk') ? 'apk' : a.name.endsWith('.ipa') ? 'ipa' : null
    if (kind) assets[kind] = { name: a.name, url: a.browser_download_url, size: a.size, n: a.download_count }
  }
  return { tag: r.tag_name, url: r.html_url, date: r.published_at, assets }
}

const loadReleases = async () => {
  try {
    const c = JSON.parse(sessionStorage.getItem('ripplo-rel'))
    if (c && Date.now() - c.t < 600000) return c.d
  } catch {}
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, { headers: { Accept: 'application/vnd.github+json' } })
  if (!res.ok) throw new Error(res.status)
  const d = (await res.json()).filter(r => !r.draft).map(slim)
  try { sessionStorage.setItem('ripplo-rel', JSON.stringify({ t: Date.now(), d })) } catch {}
  return d
}

const countUp = (el, to) => {
  if (reduce) { el.textContent = nf.format(to); return }
  const run = () => {
    const t0 = performance.now()
    const tick = now => {
      const k = Math.min((now - t0) / 1400, 1)
      el.textContent = nf.format(Math.round(to * (1 - Math.pow(1 - k, 4))))
      if (k < 1) requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  }
  if (!('IntersectionObserver' in window)) { run(); return }
  const io = new IntersectionObserver(es => { if (es[0].isIntersecting) { io.disconnect(); run() } }, { threshold: 0.4 })
  io.observe(el)
}

const row = r => {
  const tr = document.createElement('tr')
  const v = document.createElement('td')
  const a = document.createElement('a')
  a.href = r.url
  a.rel = 'noopener'
  a.textContent = r.tag
  v.append(a)
  const d = document.createElement('td')
  d.textContent = new Date(r.date).toLocaleDateString(root.lang, { year: 'numeric', month: 'short', day: 'numeric' })
  tr.append(v, d)
  return tr
}

const fill = rels => {
  const latest = rels[0]
  const sum = k => rels.reduce((s, r) => s + (r.assets[k] ? r.assets[k].n : 0), 0)
  const apk = sum('apk')
  const ipa = sum('ipa')
  const vals = { total: apk + ipa, latest: latest ? (latest.assets.apk ? latest.assets.apk.n : 0) + (latest.assets.ipa ? latest.assets.ipa.n : 0) : 0, releases: rels.length, apk, ipa }
  $$('[data-count]').forEach(el => countUp(el, vals[el.dataset.count]))
  if (!latest) return
  $('#hero-ver').textContent = `${L.ver} ${latest.tag}`
  $('#stat-ver').textContent = latest.tag
  $$('[data-dl]').forEach(el => {
    const kind = el.dataset.dl === 'auto' ? os : el.dataset.dl
    if (latest.assets[kind]) el.href = latest.assets[kind].url
  })
  $$('[data-meta]').forEach(el => {
    const a = latest.assets[el.dataset.meta]
    if (a) el.textContent = `${a.name} · ${(a.size / 1048576).toFixed(1)} MB · ${nf.format(a.n)} ${L.dls}`
  })
  $('#rel-body').replaceChildren(...rels.map(row))
}

$$('a[hreflang]').forEach(a => a.addEventListener('click', () => {
  try { localStorage.setItem('ripplo-lang', a.hreflang) } catch {}
}))
$(`#card-${os}`)?.classList.add('pick')

loadReleases().then(fill).catch(() => {
  $$('[data-count]').forEach(el => { el.textContent = '–' })
})

const rv = $$('.rv')
if ('IntersectionObserver' in window && !reduce) {
  const io = new IntersectionObserver(es => {
    for (const e of es) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target) }
  }, { threshold: 0.12, rootMargin: '0px 0px -6% 0px' })
  rv.forEach(el => io.observe(el))
} else {
  rv.forEach(el => el.classList.add('in'))
}

$$('.card').forEach(c => c.addEventListener('pointermove', e => {
  const b = c.getBoundingClientRect()
  c.style.setProperty('--mx', `${e.clientX - b.left}px`)
  c.style.setProperty('--my', `${e.clientY - b.top}px`)
}))

$$('.sheet a').forEach(a => a.addEventListener('click', () => { $('.menu').open = false }))

const dock = $('#dock')
if (dock && 'IntersectionObserver' in window) {
  const seen = new Set()
  const io = new IntersectionObserver(es => {
    for (const e of es) e.isIntersecting ? seen.add(e.target.id) : seen.delete(e.target.id)
    dock.classList.toggle('on', seen.size === 0 && scrollY > 200)
  })
  io.observe($('#hero'))
  io.observe($('#download'))
}

const cv = $('#mesh')
if (cv) {
  const ctx = cv.getContext('2d')
  let w = 0, h = 0, nodes = [], pk = [], last = 0, spawn = 0, raf = 0
  const reach = () => Math.min(170, Math.max(110, w / 5))
  const near = a => nodes.filter(b => b !== a && Math.hypot(a.x - b.x, a.y - b.y) < reach())
  const send = (a, hops) => {
    const ns = near(a)
    if (ns.length && pk.length < 40) pk.push({ a, b: ns[(Math.random() * ns.length) | 0], t: 0, hops })
  }
  const size = () => {
    const dpr = Math.min(devicePixelRatio || 1, 2)
    w = cv.clientWidth
    h = cv.clientHeight
    cv.width = w * dpr
    cv.height = h * dpr
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    const n = Math.round(Math.min(46, Math.max(18, (w * h) / 22000)))
    nodes = Array.from({ length: n }, () => ({ x: Math.random() * w, y: Math.random() * h, vx: (Math.random() - 0.5) * 0.25, vy: (Math.random() - 0.5) * 0.25, r: 1.5 + Math.random() * 1.5 }))
    pk = []
  }
  const frame = ts => {
    const dt = Math.min(ts - last, 50) || 16
    last = ts
    const R = reach()
    ctx.clearRect(0, 0, w, h)
    for (const n of nodes) {
      n.x += (n.vx * dt) / 16
      n.y += (n.vy * dt) / 16
      if (n.x < 0 || n.x > w) n.vx *= -1
      if (n.y < 0 || n.y > h) n.vy *= -1
    }
    ctx.lineWidth = 1
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const a = nodes[i], b = nodes[j], d = Math.hypot(a.x - b.x, a.y - b.y)
        if (d < R) {
          ctx.strokeStyle = `rgba(120,150,255,${(1 - d / R) * 0.28})`
          ctx.beginPath()
          ctx.moveTo(a.x, a.y)
          ctx.lineTo(b.x, b.y)
          ctx.stroke()
        }
      }
    }
    ctx.fillStyle = 'rgba(180,200,255,.55)'
    for (const n of nodes) {
      ctx.beginPath()
      ctx.arc(n.x, n.y, n.r, 0, 7)
      ctx.fill()
    }
    spawn -= dt
    if (spawn <= 0 && nodes.length) {
      spawn = 500 + Math.random() * 700
      send(nodes[(Math.random() * nodes.length) | 0], 3 + ((Math.random() * 3) | 0))
    }
    pk = pk.filter(p => {
      p.t += dt / 380
      if (p.t >= 1) {
        if (p.hops > 0) send(p.b, p.hops - 1)
        return false
      }
      const x = p.a.x + (p.b.x - p.a.x) * p.t
      const y = p.a.y + (p.b.y - p.a.y) * p.t
      ctx.fillStyle = 'rgba(91,140,255,.22)'
      ctx.beginPath()
      ctx.arc(x, y, 9, 0, 7)
      ctx.fill()
      ctx.fillStyle = '#fff'
      ctx.beginPath()
      ctx.arc(x, y, 2.6, 0, 7)
      ctx.fill()
      return true
    })
    if (!reduce) raf = requestAnimationFrame(frame)
  }
  const start = () => { if (!raf && !reduce) raf = requestAnimationFrame(frame) }
  const stop = () => { cancelAnimationFrame(raf); raf = 0 }
  size()
  frame(16)
  if (!reduce) {
    let lw = innerWidth
    addEventListener('resize', () => {
      if (innerWidth !== lw) { lw = innerWidth; size() }
    })
    new IntersectionObserver(es => (es[0].isIntersecting ? start() : stop())).observe(cv)
    document.addEventListener('visibilitychange', () => (document.hidden ? stop() : start()))
  }
}
