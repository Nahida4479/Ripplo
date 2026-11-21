<script setup>
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import QRCode from 'qrcode'
import { ChevronLeft, ShieldCheck, ShieldAlert } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { safetyNumber, verifyNearby, markVerified, deleteContact } from '../core/api.js'
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

onMounted(async () => {
  digits.value = await safetyNumber(id)
  qr.value = await QRCode.toDataURL(digits.value, { margin: 1, width: 360 })
})
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
      <Avatar :name="c.name" :size="88" />
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
          </div>
        </div>
      </div>
    </div>

    <h2 class="section">{{ t('safetyNumber') }}</h2>
    <div class="card pad" style="text-align: center">
      <div class="mono sn"><span v-for="(g, i) in groups" :key="i">{{ g }}</span></div>
      <img v-if="qr" :src="qr" class="qr" :alt="t('safetyNumber')" />
      <p class="hint" style="color: var(--text-2); font-size: 13px; margin: 8px 0 0">{{ t('safetyHint') }}</p>
    </div>

    <div style="display: grid; gap: 8px">
      <button class="btn" @click="ui.add = { mode: 'verify', id }">{{ t('verifyQr') }}</button>
      <button class="btn ghost" :disabled="c.verifyState === 'checking'" @click="retry">{{ t(c.verifyState === 'checking' ? 'checking' : 'retryNearby') }}</button>
      <button v-if="!verified" class="btn ghost" @click="sure">{{ t('imSure') }}</button>
      <button class="btn danger" @click="del">{{ t('deleteContact') }}</button>
    </div>
  </main>
</template>
<style scoped>
.sn { display: grid; grid-template-columns: repeat(4, auto); justify-content: center; gap: 6px 14px; font-size: 16px; margin-bottom: 14px; }
.qr { width: 180px; border-radius: 12px; background: #fff; padding: 6px; image-rendering: pixelated; }
</style>
