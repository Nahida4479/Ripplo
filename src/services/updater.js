import { watch } from 'vue'
import { App } from '@capacitor/app'
import { Capacitor } from '@capacitor/core'
import { state } from '../core/state.js'
import { mesh } from '../mesh/bridge.js'
import { t, locale } from '../i18n.js'
import { createGithub } from '../lib/githubCache.js'
import { ui } from '../components/ui.js'

const REPO = 'https://api.github.com/repos/Nahida4479/Ripplo/releases'
const native = Capacitor.getPlatform() === 'android'

const num = v => v.replace(/^v/, '').split('.').map(n => parseInt(n, 10) || 0)
export function newer(a, b) {
  const x = num(a), y = num(b)
  for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0)
  return false
}

const storage = (() => { try { return localStorage } catch { return { getItem: () => null, setItem() {} } } })()
const getJson = createGithub({ storage })
const DAY = 24 * 3600e3
const explain = e => e.code === 'rate'
  ? t('err_rate_limit', { time: new Date(e.until).toLocaleTimeString(locale.value, { hour: '2-digit', minute: '2-digit' }) })
  : e.message
const hashOf = (rel, name) => {
  const digest = rel.assets.find(x => x.name === name)?.digest
  if (digest?.startsWith('sha256:')) return digest.slice(7)
  return (rel.body || '').split('\n').map(l => l.trim().split(/\s+/)).find(([h, f]) => f === name && /^[0-9a-f]{64}$/i.test(h))?.[0] || null
}

let current
const version = () => current ??= (Capacitor.isNativePlatform() ? App.getInfo().then(i => i.version) : Promise.resolve(__APP_VERSION__))
  .catch(() => __APP_VERSION__).then(v => (state.update.current = v))

export async function checkUpdate(manual) {
  const u = state.update
  const cur = await version()
  if (!navigator.onLine || u.checking) return
  u.checking = true; u.error = null
  const t0 = Date.now()
  try {
    const rel = await getJson(`${REPO}/latest`, manual === true ? { maxAge: 60e3 } : undefined)
    u.latest = rel.tag_name.replace(/^v/, '')
    u.url = rel.html_url
    u.available = newer(u.latest, cur)
    const apk = rel.assets.find(a => a.name === `Ripplo-${rel.tag_name}.apk`)
    u.apkUrl = apk?.browser_download_url || null
    u.sha256 = hashOf(rel, `Ripplo-${rel.tag_name}.apk`)
    u.checkedAt = Date.now()
    if (u.available) promptUpdate()
  } catch (e) {
    u.error = explain(e)
  } finally {
    await new Promise(r => setTimeout(r, Math.max(0, 800 - (Date.now() - t0))))
    u.checking = false
  }
}

const PROMPT_GAP = 6 * 3600e3
function promptUpdate() {
  const u = state.update
  if (ui.confirm || Date.now() - u.promptedAt < PROMPT_GAP) return
  u.promptedAt = Date.now()
  const direct = native && u.apkUrl && u.sha256
  ui.confirm = {
    title: t('updateFound', { version: u.latest }), text: t(direct ? 'updateAsk' : 'updateAskWeb'),
    ok: t(direct ? 'updateNow' : 'openRelease'), cancel: t('later'),
    onOk: () => direct ? install() : window.open(u.url, '_blank', 'noopener')
  }
}

export async function install(prompt = true) {
  const u = state.update
  if (u.installing) return
  u.installing = true
  u.error = null
  u.progress = 0
  const off = mesh.on('updateProgress', ({ progress }) => { u.progress = progress })
  try { await mesh.installUpdate(u.apkUrl, u.sha256, prompt) } catch (e) { u.error = e.message === 'install_permission' ? t('err_install_permission') : e.message } finally { off(); u.progress = null; u.installing = false }
}

export async function checkIntegrity() {
  const i = state.integrity
  try {
    if (!native) { Object.assign(i, { status: 'unsupported', checkedAt: Date.now() }); return }
    const mine = await mesh.selfHash()
    if (!mine) { i.status = 'unsupported'; return }
    if (!navigator.onLine) { i.status = 'offline'; return }
    const tag = `v${await version()}`
    const hash = hashOf(await getJson(`${REPO}/tags/${tag}`, { maxAge: DAY }), `Ripplo-${tag}.apk`)
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
  App.addListener('resume', () => { if (Date.now() - state.update.checkedAt > 10 * 60e3) run() })
  if (native) watch(() => state.settings.autoUpdate, on => mesh.setAutoUpdate(!!on).catch(() => {}), { immediate: true })
}
