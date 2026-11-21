<script setup>
import { ref, computed } from 'vue'
import { QrCode, ExternalLink, ShieldCheck, ShieldAlert, ShieldQuestion, TriangleAlert } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { saveSettings } from '../core/api.js'
import { mesh } from '../mesh/bridge.js'
import { ui } from '../components/ui.js'
import { t, locale, setLocale } from '../i18n.js'
import { theme, ACCENTS, GRADIENTS } from '../services/theme.js'
import { checkUpdate, install } from '../services/updater.js'
import { contributors } from '../contributors.js'
import Avatar from '../components/Avatar.vue'
import BackupCard from '../components/BackupCard.vue'
import { setAppLock } from '../services/lock.js'
import { Capacitor } from '@capacitor/core'

const android = Capacitor.getPlatform() === 'android'
const REPO = 'https://github.com/Nahida4479/Ripplo'
const custom = computed(() => !ACCENTS.includes(theme.accent))
const broken = ref({})
const integ = computed(() => ({
  ok: [ShieldCheck, 'ok', 'integrityOk'], mismatch: [ShieldAlert, 'bad', 'integrityBad']
}[state.integrity.status] || [ShieldQuestion, '', 'integrityUnknown']))
const kbps = n => n.kbps >= 1000 ? (n.kbps / 1000).toFixed(1) + ' Mbps' : n.kbps + ' kbps'
const initials = l => l.slice(0, 2).toUpperCase()
</script>
<template>
  <main class="page">
    <header class="hdr"><h1>{{ t('settings') }}</h1></header>

    <h2 class="section">{{ t('profile') }}</h2>
    <div class="card">
      <div class="row"><Avatar :name="state.profile?.name" :size="44" />
        <span class="grow"><span class="label">{{ state.profile?.name }}</span><br /><span class="hint mono">{{ state.profile?.ripploId }}</span></span></div>
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
      <div v-for="n in state.neighbors" :key="n.node" class="row">
        <span class="grow"><span class="label">{{ n.card?.name || n.node.slice(0, 8) }}</span><br />
          <span class="hint">{{ [...new Set((n.links?.length ? n.links : [n]).map(l => String(l.medium).toUpperCase()))].join(' + ') }} · {{ kbps(n) }}</span></span>
        <span class="chip ok">{{ t('connected') }}</span>
      </div>
      <div class="row">
        <span class="grow"><span class="label">{{ t('backgroundRelay') }}</span><br /><span class="hint">{{ t('relayHint') }}</span></span>
        <button class="switch" role="switch" :aria-checked="state.settings.backgroundRelay" :aria-label="t('backgroundRelay')" @click="saveSettings({ backgroundRelay: !state.settings.backgroundRelay })" />
      </div>
      <button v-if="android" class="row" @click="mesh.requestBatteryExemption()"><span class="grow label">{{ t('batteryExemption') }}</span></button>
    </div>

    <h2 class="section">{{ t('security') }}</h2>
    <div class="card">
      <div v-if="state.devCrypto" class="row" style="color: var(--danger); font-weight: 600"><TriangleAlert :size="22" /><span class="grow">{{ t('devCryptoWarn') }}</span></div>
      <div class="row"><component :is="integ[0]" :size="22" :stroke-width="1.75" /><span class="grow"><span class="label">{{ t('integrity') }}</span><br /><span class="hint">{{ t(integ[2]) }}</span></span></div>
      <div class="row" :style="state.insecureStorage ? 'color: var(--warn)' : ''">
        <TriangleAlert v-if="state.insecureStorage" :size="22" /><ShieldCheck v-else :size="22" :stroke-width="1.75" />
        <span class="grow"><span class="label">{{ t('dbEncryption') }}</span><br /><span class="hint">{{ t(state.insecureStorage ? 'dbInsecure' : 'dbSecure') }}</span></span></div>
      <div class="row"><span class="grow"><span class="label">{{ t('signal') }}</span><br /><span class="hint">{{ t('signalInfo') }}</span></span></div>
      <div v-if="mesh.isNative" class="row">
        <span class="grow"><span class="label">{{ t('appLock') }}</span><br /><span class="hint">{{ t('appLockHint') }}</span></span>
        <button class="switch" role="switch" :aria-checked="!!state.settings.appLock" :aria-label="t('appLock')" @click="setAppLock(!state.settings.appLock)" />
      </div>
    </div>

    <BackupCard />

    <h2 class="section">{{ t('updates') }}</h2>
    <div class="card">
      <div class="row"><span class="grow label">{{ t('currentVersion') }}</span><span class="val">{{ __APP_VERSION__ }}</span></div>
      <div class="row"><span class="grow label">{{ t('latestVersion') }}</span><span class="val">{{ state.update.latest || '–' }}</span></div>
      <div v-if="state.update.error" class="row hint">{{ state.update.error }}</div>
      <div v-if="state.update.progress != null" class="row"><progress class="grow" max="1" :value="state.update.progress" /></div>
      <div class="row">
        <button class="btn sm ghost" :disabled="state.update.checking" @click="checkUpdate">{{ t(state.update.checking ? 'checking' : 'checkNow') }}</button>
        <span class="grow" />
        <button v-if="state.update.available && android && state.update.apkUrl" class="btn sm" @click="install">{{ t('install') }}</button>
        <a v-else-if="state.update.available" class="btn sm" :href="state.update.url" target="_blank" rel="noopener">{{ t('openRelease') }}</a>
      </div>
      <div v-if="android" class="row">
        <span class="grow label">{{ t('autoUpdate') }}</span>
        <button class="switch" role="switch" :aria-checked="state.settings.autoUpdate" :aria-label="t('autoUpdate')" @click="saveSettings({ autoUpdate: !state.settings.autoUpdate })" />
      </div>
    </div>

    <h2 class="section">{{ t('about') }}</h2>
    <div class="card">
      <div class="row"><span class="grow"><span class="label">Ripplo</span><br /><span class="hint">{{ t('tagline') }}</span></span><span class="val">{{ __APP_VERSION__ }}</span></div>
      <a class="row" :href="REPO" target="_blank" rel="noopener"><span class="grow label">GitHub</span><ExternalLink :size="18" /></a>
      <div class="row"><span class="grow label">{{ t('license') }}</span><span class="val">AGPL-3.0</span></div>
    </div>
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
.contrib { display: flex; align-items: center; gap: 12px; }
.contrib img, .ini { width: 44px; height: 44px; border-radius: 50%; flex: none; }
.ini { display: grid; place-items: center; background: var(--surface-2); font-weight: 600; }
.hint { font-size: 13px; color: var(--text-2); }
.grow { flex: 1; }
progress { accent-color: var(--accent); width: 100%; }
a.row { color: inherit; }
</style>
