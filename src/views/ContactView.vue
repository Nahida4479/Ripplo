<script setup>
import { ref, computed, watch, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import QRCode from 'qrcode'
import { ChevronLeft, ShieldCheck, ShieldAlert, Play, X } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { safetyNumber, verifyNearby, markVerified, deleteContact, loadMessages } from '../core/api.js'
import { ui, toast } from '../components/ui.js'
import { t, locale } from '../i18n.js'
import Avatar from '../components/Avatar.vue'

const id = useRoute().params.id
const router = useRouter()
const c = computed(() => state.contacts[id])
const digits = ref('')
const qr = ref('')
const groups = computed(() => digits.value.match(/.{1,5}/g) || [])
const verified = computed(() => c.value?.verification !== 'none')
const date = computed(() => c.value?.verifiedAt ? new Date(c.value.verifiedAt).toLocaleDateString(locale.value) : '')

const showSafety = computed(() => !!c.value && (!verified.value || c.value.conflict))
watch(showSafety, async on => {
  if (!on || digits.value) return
  digits.value = await safetyNumber(id)
  qr.value = await QRCode.toDataURL(digits.value, { margin: 2, width: 560, errorCorrectionLevel: 'L' })
}, { immediate: true })

const viewing = ref(null)
const media = computed(() => (state.messages[id] || [])
  .filter(m => m.att && (m.att.kind === 'image' || m.att.kind === 'video') && m.att.url)
  .sort((a, b) => b.ts - a.ts))
onMounted(() => loadMessages(id))
async function retry() { toast((await verifyNearby(id)) ? t('verifiedOk') : t('verifyFailed')) }
function sure() {
  ui.confirm = { title: t('imSure'), text: t('imSureConfirm'), ok: t('confirm'), onOk: () => markVerified(id) }
}
function del() {
  ui.confirm = { title: t('deleteContact'), text: t('deleteContactConfirm'), ok: t('delete'), danger: true,
    onOk: async () => { await deleteContact(id); router.replace('/') } }
}
</script>
<template>
  <main v-if="c" class="page" style="padding-bottom: calc(var(--sab) + 24px)">
    <header class="hdr"><button class="icon-btn" :aria-label="t('back')" @click="router.back()"><ChevronLeft :size="24" /></button></header>
    <div class="center" style="min-height: 0; padding: 8px 0 20px; gap: 6px">
      <Avatar :name="c.name" :photo="c.avatar" :size="88" />
      <h1 style="margin: 8px 0 0; font-size: 24px">{{ c.name }}</h1>
      <div class="mono hint" style="color: var(--text-2); font-size: 13px">{{ c.id }}</div>
    </div>

    <div class="card pad" :style="c.conflict ? 'border-color: var(--danger)' : ''">
      <div style="display: flex; gap: 12px; align-items: center">
        <component :is="verified && !c.conflict ? ShieldCheck : ShieldAlert" :size="28" :color="c.conflict ? 'var(--danger)' : verified ? 'var(--ok)' : 'var(--warn)'" />
        <div>
          <div class="label" style="font-weight: 600">{{ c.conflict ? t('conflict') : verified ? t('verified') : t('notVerified') }}</div>
          <div class="hint" style="color: var(--text-2); font-size: 13px">
            <template v-if="verified">{{ t('method_' + c.verification) }} · {{ date }}</template>
            <template v-else>{{ t('unverifiedWarning') }}</template>
            <template v-if="c.peerVerified && !verified"><br />{{ t('peerVerified', { name: c.name, method: t('method_' + c.peerVerified.level) }) }}</template>
          </div>
        </div>
      </div>
    </div>

    <h2 class="section">{{ t('media') }}<template v-if="media.length"> · {{ media.length }}</template></h2>
    <div class="card pad">
      <p v-if="!media.length" class="hint" style="margin: 0">{{ t('noMedia') }}</p>
      <div v-else class="grid">
        <button v-for="m in media" :key="m.id" class="tile" :aria-label="t(m.att.kind === 'video' ? 'videoMessage' : 'photoMessage')" @click="viewing = m">
          <img v-if="m.att.kind === 'image'" :src="m.att.url" alt="" />
          <template v-else><video :src="m.att.url" preload="metadata" muted playsinline /><Play class="pi" :size="22" /></template>
        </button>
      </div>
    </div>

    <h2 v-if="showSafety" class="section">{{ t('safetyNumber') }}</h2>
    <div v-if="showSafety" class="card pad" style="text-align: center">
      <div class="mono sn"><span v-for="(g, i) in groups" :key="i">{{ g }}</span></div>
      <img v-if="qr" :src="qr" class="qr" :alt="t('safetyNumber')" />
      <p class="hint" style="color: var(--text-2); font-size: 13px; margin: 8px 0 0">{{ t('safetyHint') }}</p>
    </div>

    <div style="display: grid; gap: 8px">
      <button v-if="showSafety" class="btn" @click="ui.add = { mode: 'verify', id }">{{ t('verifyQr') }}</button>
      <button v-if="showSafety" class="btn ghost" :disabled="c.verifyState === 'checking'" @click="retry">{{ t(c.verifyState === 'checking' ? 'checking' : 'retryNearby') }}</button>
      <button v-if="!verified" class="btn ghost" @click="sure">{{ t('imSure') }}</button>
      <button class="btn danger" @click="del">{{ t('deleteContact') }}</button>
    </div>
    <div v-if="viewing" class="viewer" role="dialog" aria-modal="true" @click.self="viewing = null">
      <button class="icon-btn close" :aria-label="t('close')" @click="viewing = null"><X :size="24" /></button>
      <img v-if="viewing.att.kind === 'image'" :src="viewing.att.url" alt="" />
      <video v-else :src="viewing.att.url" controls autoplay playsinline />
    </div>
  </main>
</template>
<style scoped>
.grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 4px; }
.tile { position: relative; aspect-ratio: 1; border-radius: 10px; overflow: hidden; background: var(--surface-2); padding: 0; }
.tile img, .tile video { width: 100%; height: 100%; object-fit: cover; display: block; }
.tile .pi { position: absolute; inset: 0; margin: auto; color: #fff; filter: drop-shadow(0 1px 3px rgba(0, 0, 0, .6)); }
.viewer { position: fixed; inset: 0; z-index: 60; background: rgba(0, 0, 0, .92); display: grid; place-items: center; padding: calc(var(--sat, 0px) + 56px) 12px calc(var(--sab, 0px) + 12px); }
.viewer img, .viewer video { max-width: 100%; max-height: 100%; border-radius: 8px; }
.viewer .close { position: absolute; top: calc(var(--sat, 0px) + 8px); right: 8px; color: #fff; }
.sn { display: grid; grid-template-columns: repeat(4, auto); justify-content: center; gap: 6px 14px; font-size: 16px; margin-bottom: 14px; }
.qr { width: 230px; border-radius: 12px; background: #fff; padding: 6px; image-rendering: pixelated; }
</style>
