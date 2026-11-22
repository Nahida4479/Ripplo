<script setup>
import { ref, computed, onMounted } from 'vue'
import { QrCode, ExternalLink, ShieldCheck, ShieldAlert, ShieldQuestion, TriangleAlert, Lock } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { saveSettings, setAvatar, setName } from '../core/api.js'
import { mesh } from '../mesh/bridge.js'
import { ui, toast } from '../components/ui.js'
import { makeAvatar } from '../lib/avatar.js'
import { t, locale, setLocale } from '../i18n.js'
import { theme, ACCENTS, GRADIENTS } from '../services/theme.js'
import { checkUpdate, install } from '../services/updater.js'
import { contributors } from '../contributors.js'
import Avatar from '../components/Avatar.vue'
import BackupCard from '../components/BackupCard.vue'
import { setAppLock } from '../services/lock.js'
import { Capacitor } from '@capacitor/core'
import { diagText, diagClear } from '../core/diag.js'

const android = Capacitor.getPlatform() === 'android'
const REPO = 'https://github.com/Nahida4479/Ripplo'
const custom = computed(() => !ACCENTS.includes(theme.accent))
const broken = ref({})
const integ = computed(() => ({
  ok: [ShieldCheck, 'ok', 'integrityOk'], mismatch: [ShieldAlert, 'bad', 'integrityBad']
}[state.integrity.status] || [ShieldQuestion, '', 'integrityUnknown']))
const kbps = n => n.kbps >= 1000 ? (n.kbps / 1000).toFixed(1) + ' Mbps' : n.kbps + ' kbps'
let devTaps = 0
let devTimer = null
function aboutTap() {
  devTaps++
  clearTimeout(devTimer)
  devTimer = setTimeout(() => { devTaps = 0 }, 2000)
  if (devTaps < 5) return
  devTaps = 0
  const on = !state.settings.dev
  saveSettings({ dev: on })
  toast(t(on ? 'devOn' : 'devOff'))
  if (on) loadDev()
}
const devLog = ref('')
const bleCaps = ref({ coded: false, extended: false, enabled: false })
const forceSpec = ref({})
const SPECS = ['lan', 'wifi-direct', 'wifi-aware', 'ble:1m', 'ble:coded']
const specOf = n => forceSpec.value[n.node] || 'lan'
const specName = s => ({ lan: 'LAN', 'wifi-direct': 'Wi-Fi Direct', 'wifi-aware': 'Wi-Fi Aware', 'ble:1m': 'BLE 1M PHY', 'ble:coded': 'BLE Coded PHY' }[s])
async function forceConnect(n) {
  const ok = await mesh.devConnect(n.node, specOf(n))
  toast(t(ok ? 'devStarted' : 'devNotStarted'))
  setTimeout(loadDev, 1500)
}
async function forceClose(n) {
  await mesh.devDisconnect(n.node, specOf(n).split(':')[0])
  setTimeout(loadDev, 500)
}
async function toggleCoded() {
  await mesh.setBleCoded(!bleCaps.value.enabled)
  await loadDev()
}
const devTransports = ref([])
async function loadDev() {
  devTransports.value = (await mesh.getTransports()) || []
  bleCaps.value = await mesh.getBleCaps()
  const native = await mesh.getDiag()
  devLog.value = (native ? native + '\n--- JS ---\n' : '') + diagText()
}
onMounted(() => { if (state.settings.dev) loadDev() })
async function clearDev() {
  await mesh.clearDiag()
  diagClear()
  await loadDev()
}
async function copyDev() {
  try { await navigator.clipboard.writeText(devLog.value); toast(t('copiedLog')) } catch { toast(t('err_bad_link')) }
}
const openNode = ref(null)
const detail = ref([])
async function toggleNet(n) {
  if (openNode.value === n.node) { openNode.value = null; return }
  openNode.value = n.node
  let fresh = null
  try { fresh = ((await mesh.getNeighbors()) || []).find(x => x.node === n.node) } catch {}
  const links = fresh?.links?.length ? fresh.links : n.links?.length ? n.links : [n]
  detail.value = [
    'node ' + n.node,
    'card ' + (n.card ? n.card.id + ' (' + n.card.name + ')' : 'none'),
    'unsupported ' + !!n.unsupported,
    ...links.map(l => String(l.medium) + ' ' + l.kbps + ' kbps' + (l.rttMs ? ' rtt ' + l.rttMs + ' ms' : '') + (l.outbound === undefined ? '' : l.outbound ? ' out' : ' in'))
  ]
  console.info('ripplo net ' + JSON.stringify(detail.value))
}
const photoInput = ref(null)
const draft = ref(null)
async function saveName() {
  try { await setName(draft.value); draft.value = null } catch (e) { toast(t('err_' + (e.code || 'bad_name'))) }
}
async function pickPhoto(e) {
  const file = e.target.files[0]
  e.target.value = ''
  if (!file) return
  try { await setAvatar(await makeAvatar(file)) } catch { toast(t('err_bad_avatar')) }
}
const initials = l => l.slice(0, 2).toUpperCase()
</script>
<template>
  <main class="page">
    <header class="hdr"><h1>{{ t('settings') }}</h1></header>

    <h2 class="section">{{ t('profile') }}</h2>
    <div class="card">
      <div class="row profrow">
        <div class="avcol">
          <button class="icon-btn" style="width: auto; height: auto" :aria-label="t('changePhoto')" @click="photoInput.click()"><Avatar :name="state.profile?.name" :photo="state.profile?.avatar" :size="44" /></button>
          <button v-if="state.profile?.avatar && draft === null" class="btn sm ghost" @click="setAvatar('')">{{ t('removePhoto') }}</button>
        </div>
        <button v-if="draft === null" class="grow wrap namebtn" :aria-label="t('changeName')" @click="draft = state.profile?.name"><span class="label">{{ state.profile?.name }}</span><span class="hint mono">{{ state.profile?.ripploId }}</span></button>
        <input v-else v-model="draft" class="field grow" maxlength="40" :aria-label="t('yourName')" @keyup.enter="saveName" />
        <input ref="photoInput" type="file" accept="image/*" hidden @change="pickPhoto" />
      </div>
      <div v-if="draft !== null" class="row profile-acts">
        <button class="btn sm ghost" @click="draft = null">{{ t('cancel') }}</button>
        <button class="btn sm" @click="saveName">{{ t('save') }}</button>
      </div>
      <div class="row hint">{{ t('photoHint') }}</div>
      <div class="row">
        <span class="grow"><span class="label">{{ t('discoverable') }}</span><br /><span class="hint">{{ t('discoverableHint') }}</span></span>
        <button class="switch" role="switch" :aria-checked="!state.settings.hidden" :aria-label="t('discoverable')" @click="saveSettings({ hidden: !state.settings.hidden })" />
      </div>
      <button class="row" @click="ui.add = { mode: 'add' }"><QrCode :size="22" :stroke-width="1.75" /><span class="grow label">{{ t('myCode') }}</span></button>
    </div>

    <h2 class="section">{{ t('appearance') }}</h2>
    <div class="card pad" style="display: grid; gap: 16px">
      <div class="seg" role="group" :aria-label="t('themeMode')">
        <button v-for="m in ['system', 'dark', 'light']" :key="m" :aria-pressed="theme.mode === m" @click="theme.mode = m">{{ t('mode_' + m) }}</button>
      </div>
      <div><div class="hint">{{ t('accent') }}</div>
        <div class="swatches">
          <button v-for="c in ACCENTS" :key="c" class="sw" :style="{ background: c }" :aria-label="c" :aria-pressed="theme.accent === c" @click="theme.accent = c" />
          <label class="sw rainbow" :aria-pressed="custom" :title="t('customColor')">
            <input type="color" :value="theme.accent" :aria-label="t('customColor')" @input="theme.accent = $event.target.value" />
          </label>
        </div></div>
      <div><div class="hint">{{ t('background') }}</div>
        <div class="swatches">
          <button v-for="g in GRADIENTS" :key="g" class="sw" :class="{ none: !g }" :style="g && { background: g }" :aria-label="g || t('none')" :aria-pressed="theme.gradient === g" @click="theme.gradient = g" />
        </div></div>
      <div class="seg" role="group" :aria-label="t('language')">
        <button v-for="l in ['en', 'pl']" :key="l" :aria-pressed="locale === l" @click="setLocale(l)">{{ l === 'en' ? 'English' : 'Polski' }}</button>
      </div>
    </div>

    <h2 class="section">{{ t('network') }}</h2>
    <div class="card">
      <div v-if="!state.neighbors.length" class="row hint">{{ t('noNeighbors') }}</div>
      <template v-for="n in state.neighbors" :key="n.node">
      <div class="row" role="button" tabindex="0" @click="toggleNet(n)" @keyup.enter="toggleNet(n)">
        <span class="grow"><span class="label">{{ n.card?.name || n.node.slice(0, 8) }}</span><br />
          <span class="hint">{{ [...new Set((n.links?.length ? n.links : [n]).map(l => String(l.medium).toUpperCase()))].join(' + ') }} · {{ kbps(n) }}</span></span>
        <span v-if="n.unsupported" class="chip">{{ t('updateNeeded') }}</span>
        <span v-else class="chip ok">{{ t('connected') }}</span>
      </div>
      <div v-if="openNode === n.node" class="row netinfo"><span class="hint mono">{{ detail.join('\n') }}</span></div>
      </template>
      <div class="row">
        <span class="grow"><span class="label">{{ t('backgroundRelay') }}</span><br /><span class="hint">{{ t('relayHint') }}</span></span>
        <button class="switch" role="switch" :aria-checked="state.settings.backgroundRelay" :aria-label="t('backgroundRelay')" @click="saveSettings({ backgroundRelay: !state.settings.backgroundRelay })" />
      </div>
    </div>

    <h2 class="section">{{ t('security') }}</h2>
    <div class="card">
      <div v-if="state.devCrypto" class="row" style="color: var(--danger); font-weight: 600"><TriangleAlert :size="22" /><span class="grow">{{ t('devCryptoWarn') }}</span></div>
      <div class="row"><component :is="integ[0]" :size="22" :stroke-width="1.75" /><span class="grow"><span class="label">{{ t('integrity') }}</span><br /><span class="hint">{{ t(integ[2]) }}</span></span></div>
      <div class="row" :style="state.insecureStorage ? 'color: var(--warn)' : ''">
        <TriangleAlert v-if="state.insecureStorage" :size="22" /><ShieldCheck v-else :size="22" :stroke-width="1.75" />
        <span class="grow"><span class="label">{{ t('dbEncryption') }}</span><br /><span class="hint">{{ t(state.insecureStorage ? 'dbInsecure' : 'dbSecure') }}</span></span></div>
      <div class="row"><Lock :size="22" :stroke-width="1.75" /><span class="grow"><span class="label">{{ t('signal') }}</span><br /><span class="hint">{{ t('signalInfo') }}</span></span></div>
      <div v-if="mesh.isNative" class="row">
        <span class="grow"><span class="label">{{ t('appLock') }}</span><br /><span class="hint">{{ t('appLockHint') }}</span></span>
        <button class="switch" role="switch" :aria-checked="!!state.settings.appLock" :aria-label="t('appLock')" @click="setAppLock(!state.settings.appLock)" />
      </div>
    </div>

    <BackupCard />

    <h2 class="section">{{ t('updates') }}</h2>
    <div class="card">
      <div class="row"><span class="grow label">{{ t('currentVersion') }}</span><span class="val">{{ state.update.current || '–' }}</span></div>
      <div class="row"><span class="grow label">{{ t('latestVersion') }}</span><span class="val">{{ state.update.latest || '–' }}</span></div>
      <div v-if="state.update.error" class="row hint">{{ state.update.error }}</div>
      <div v-if="state.update.progress != null" class="row"><progress class="grow" max="1" :value="state.update.progress" /></div>
      <div class="row">
        <button class="btn sm" :disabled="state.update.checking" @click="checkUpdate(true)">{{ t(state.update.checking ? 'checking' : 'checkNow') }}</button>
        <span class="grow" />
        <button v-if="state.update.available && android && state.update.apkUrl" class="btn sm" :disabled="state.update.installing || state.update.checking" @click="install()">{{ t('install') }}</button>
        <a v-else-if="state.update.available" class="btn sm" :href="state.update.url" target="_blank" rel="noopener">{{ t('openRelease') }}</a>
      </div>
      <div v-if="android" class="row">
        <span class="grow label">{{ t('autoUpdate') }}</span>
        <button class="switch" role="switch" :aria-checked="state.settings.autoUpdate" :aria-label="t('autoUpdate')" @click="saveSettings({ autoUpdate: !state.settings.autoUpdate })" />
      </div>
    </div>

    <h2 class="section">{{ t('about') }}</h2>
    <div class="card">
      <div class="row" role="button" tabindex="0" @click="aboutTap"><span class="grow"><span class="label">Ripplo</span><br /><span class="hint">{{ t('tagline') }}</span></span><span class="val">{{ state.update.current || '–' }}</span></div>
      <a class="row" :href="REPO" target="_blank" rel="noopener"><span class="grow label">GitHub</span><ExternalLink :size="18" /></a>
      <div class="row"><span class="grow label">{{ t('license') }}</span><span class="val">AGPL-3.0</span></div>
    </div>
    <template v-if="state.settings.dev">
      <h2 class="section">{{ t('developer') }}</h2>
      <div class="card">
        <div v-for="x in devTransports" :key="x.name" class="row"><span class="grow label">{{ x.name }}</span><span class="chip" :class="x.running ? 'ok' : x.unsupported ? 'bad' : 'warn'">{{ x.running ? 'running' : x.unsupported ? 'unsupported' : 'stopped' }}</span></div>
        <div class="row">
          <span class="grow"><span class="label">{{ t('devBleCoded') }}</span><br /><span class="hint">{{ t('devBleCodedHint', { coded: bleCaps.coded ? '✓' : '✗', ext: bleCaps.extended ? '✓' : '✗' }) }}</span></span>
          <button class="switch" role="switch" :aria-checked="bleCaps.enabled" :aria-label="t('devBleCoded')" :disabled="!bleCaps.coded || !bleCaps.extended" @click="toggleCoded" />
        </div>
        <div class="row hint">{{ t('devForce') }}</div>
        <div v-for="n in state.neighbors" :key="n.node" class="row forcerow">
          <span class="grow label">{{ n.card?.name || n.node.slice(0, 8) }}</span>
          <select class="field" :value="specOf(n)" :aria-label="t('devForce')" @change="forceSpec[n.node] = $event.target.value">
            <option v-for="s in SPECS" :key="s" :value="s">{{ specName(s) }}</option>
          </select>
          <button class="btn sm" @click="forceConnect(n)">{{ t('devConnectBtn') }}</button>
          <button class="btn sm ghost" @click="forceClose(n)">{{ t('devClose') }}</button>
        </div>
        <div class="row netinfo"><span class="hint mono devlog">{{ devLog || '–' }}</span></div>
        <div class="row profile-acts">
          <button class="btn sm ghost" @click="loadDev">{{ t('refresh') }}</button>
          <button class="btn sm ghost" @click="copyDev">{{ t('copyLog') }}</button>
          <button class="btn sm ghost" @click="clearDev">{{ t('clearLog') }}</button>
        </div>
      </div>
    </template>
    <h2 class="section">{{ t('contributors') }}</h2>
    <a v-for="c in contributors" :key="c.login" class="card pad contrib" :href="'https://github.com/' + c.login" target="_blank" rel="noopener">
      <img v-if="!broken[c.login]" :src="`https://github.com/${c.login}.png?size=96`" width="44" height="44" alt="" @error="broken[c.login] = true" />
      <span v-else class="ini">{{ initials(c.login) }}</span>
      <span class="grow"><b>{{ c.login }}</b><br /><span class="hint">{{ t('githubProfile') }}</span></span>
      <ExternalLink :size="18" />
    </a>
  </main>
</template>
<style scoped>
.wrap { overflow-wrap: anywhere; }
.namebtn { text-align: left; min-width: 0; padding: 0; }
.profile-acts { flex-wrap: wrap; justify-content: flex-end; }
.avcol { display: flex; flex-direction: column; align-items: center; gap: 6px; }
.card .profrow { align-items: flex-start; }
.profrow .namebtn { height: 44px; display: flex; flex-direction: column; justify-content: center; align-items: flex-start; gap: 2px; }
.profrow .namebtn .label, .profrow .namebtn .hint { line-height: 1.2; }
.profrow .field { min-height: 44px; }
.netinfo .hint { white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; }
.forcerow { flex-wrap: wrap; }
.forcerow select { width: auto; flex: 1; min-width: 120px; }
.devlog { max-height: 280px; overflow: auto; font-size: 11px; display: block; width: 100%; }
.contrib { display: flex; align-items: center; gap: 12px; }
.contrib img, .ini { width: 44px; height: 44px; border-radius: 50%; flex: none; }
.ini { display: grid; place-items: center; background: var(--surface-2); font-weight: 600; }
.hint { font-size: 13px; color: var(--text-2); }
.grow { flex: 1; }
progress { accent-color: var(--accent); width: 100%; }
a.row { color: inherit; }
</style>
