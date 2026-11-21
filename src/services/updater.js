import { App } from '@capacitor/app'
import { Capacitor } from '@capacitor/core'
import { state } from '../core/state.js'
import { mesh } from '../mesh/bridge.js'
import { t } from '../i18n.js'

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
const hashOf = (rel, name) => {
  const digest = rel.assets.find(x => x.name === name)?.digest
  if (digest?.startsWith('sha256:')) return digest.slice(7)
  return (rel.body || '').split('\n').map(l => l.trim().split(/\s+/)).find(([h, f]) => f === name && /^[0-9a-f]{64}$/i.test(h))?.[0] || null
}

let current
const version = () => current ??= (Capacitor.isNativePlatform() ? App.getInfo().then(i => i.version) : Promise.resolve(__APP_VERSION__))
  .catch(() => __APP_VERSION__).then(v => (state.update.current = v))

export async function checkUpdate() {
  const u = state.update
  const cur = await version()
  if (!navigator.onLine || u.checking) return
  u.checking = true; u.error = null
  const t0 = Date.now()
  try {
    const rel = await getJson(`${REPO}/latest`)
    u.latest = rel.tag_name.replace(/^v/, '')
    u.url = rel.html_url
    u.available = newer(u.latest, cur)
    const apk = rel.assets.find(a => a.name === `Ripplo-${rel.tag_name}.apk`)
    u.apkUrl = apk?.browser_download_url || null
    u.sha256 = hashOf(rel, `Ripplo-${rel.tag_name}.apk`)
    u.checkedAt = Date.now()
    if (u.available && native && state.settings.autoUpdate && u.apkUrl && u.sha256) await install(false)
  } catch (e) {
    u.error = e.message
  } finally {
    await new Promise(r => setTimeout(r, Math.max(0, 800 - (Date.now() - t0))))
    u.checking = false
  }
}

export async function install(prompt = true) {
  const u = state.update
  u.error = null
  u.progress = 0
  const off = mesh.on('updateProgress', ({ progress }) => { u.progress = progress })
  try { await mesh.installUpdate(u.apkUrl, u.sha256, prompt) } catch (e) { u.error = e.message === 'install_permission' ? t('err_install_permission') : e.message } finally { off(); u.progress = null }
}

export async function checkIntegrity() {
  const i = state.integrity
  try {
    if (!native) { Object.assign(i, { status: 'unsupported', checkedAt: Date.now() }); return }
    const mine = await mesh.selfHash()
    if (!mine) { i.status = 'unsupported'; return }
    if (!navigator.onLine) { i.status = 'offline'; return }
    const tag = `v${await version()}`
    const hash = hashOf(await getJson(`${REPO}/tags/${tag}`), `Ripplo-${tag}.apk`)
    const ok = !!hash && hash.toLowerCase() === mine.toLowerCase()
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
