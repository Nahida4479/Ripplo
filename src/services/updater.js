import { App } from '@capacitor/app'
import { Capacitor } from '@capacitor/core'
import { state } from '../core/state.js'
import { mesh } from '../mesh/bridge.js'

const REPO = 'https://api.github.com/repos/Nahida4479/Ripplo/releases'
const native = Capacitor.getPlatform() === 'android'

const num = v => v.replace(/^v/, '').split('.').map(n => parseInt(n, 10) || 0)
export function newer(a, b) {
  const x = num(a), y = num(b)
  for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0)
  return false
}

const getJson = async url => {
  const r = await fetch(url, { headers: { Accept: 'application/vnd.github+json' } })
  if (!r.ok) throw new Error(String(r.status))
  return r.json()
}
const sums = async rel => {
  const a = rel.assets.find(x => x.name === 'SHA256SUMS')
  return a ? (await (await fetch(a.browser_download_url)).text()).split('\n').map(l => l.trim().split(/\s+/)) : []
}

export async function checkUpdate() {
  const u = state.update
  if (!navigator.onLine || u.checking) return
  u.checking = true; u.error = null
  try {
    const rel = await getJson(`${REPO}/latest`)
    u.latest = rel.tag_name.replace(/^v/, '')
    u.url = rel.html_url
    u.available = newer(u.latest, __APP_VERSION__)
    const apk = rel.assets.find(a => a.name === `Ripplo-${rel.tag_name}.apk`)
    u.apkUrl = apk?.browser_download_url || null
    const hash = (await sums(rel)).find(([, f]) => f === `Ripplo-${rel.tag_name}.apk`)?.[0]
    u.sha256 = hash || null
    if (u.available && native && state.settings.autoUpdate && u.apkUrl && u.sha256) await install()
  } catch (e) {
    u.error = e.message
  } finally {
    u.checking = false
  }
}

export async function install() {
  const u = state.update
  u.progress = 0
  const off = mesh.on('updateProgress', ({ progress }) => { u.progress = progress })
  try { await mesh.installUpdate(u.apkUrl, u.sha256) } catch (e) { u.error = e.message } finally { off(); u.progress = null }
}

export async function checkIntegrity() {
  const i = state.integrity
  try {
    if (!native) { Object.assign(i, { status: 'unsupported', checkedAt: Date.now() }); return }
    const mine = await mesh.selfHash()
    if (!mine) { i.status = 'unsupported'; return }
    if (!navigator.onLine) { i.status = 'offline'; return }
    const rel = await getJson(`${REPO}/tags/v${__APP_VERSION__}`)
    const ok = (await sums(rel)).some(([h, f]) => f?.endsWith('.apk') && h.toLowerCase() === mine.toLowerCase())
    Object.assign(i, { status: ok ? 'ok' : 'mismatch', checkedAt: Date.now() })
  } catch {
    i.status = 'offline'
  }
}

export function startUpdater() {
  const run = () => { checkUpdate(); checkIntegrity() }
  run()
  setInterval(run, 6 * 3600e3)
  window.addEventListener('online', run)
  App.addListener('resume', () => { if (!state.update.latest) run() })
}
