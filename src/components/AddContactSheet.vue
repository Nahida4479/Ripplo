<script setup>
import { ref, watch, onBeforeUnmount, computed, nextTick } from 'vue'
import QRCode from 'qrcode'
import jsQR from 'jsqr'
import { useRouter } from 'vue-router'
import { state } from '../core/state.js'
import { myInviteLink, addContactFromLink, verifyByQr } from '../core/api.js'
import { ui, toast } from './ui.js'
import { t } from '../i18n.js'

const router = useRouter()
const tab = ref('code')
const qr = ref('')
const link = ref('')
const pasted = ref('')
const video = ref(null)
const canvas = ref(null)
let stream, raf, busy = false
const verify = computed(() => ui.add?.mode === 'verify')

function stopScan() {
  cancelAnimationFrame(raf)
  stream?.getTracks().forEach(x => x.stop())
  stream = null
}
function close() { stopScan(); ui.add = null }

async function handle(text, via) {
  if (busy) return
  busy = true
  try {
    if (verify.value) {
      const ok = await verifyByQr(ui.add.id, text)
      toast(ok ? t('verifiedOk') : t('verifyMismatch'))
      if (!ok) { busy = false; return }
      close()
    } else {
      const c = await addContactFromLink(text, via)
      close(); router.push('/contact/' + c.id)
    }
  } catch (e) {
    toast(t('err_' + (e.code || 'bad_link')))
    busy = false
  }
}

async function startScan() {
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } })
  } catch { toast(t('cameraDenied')); return }
  await nextTick()
  const v = video.value
  if (!v) return stopScan()
  v.srcObject = stream
  await v.play().catch(() => {})
  const ctx = canvas.value.getContext('2d', { willReadFrequently: true })
  const loop = () => {
    if (!stream) return
    if (v.readyState >= 2 && v.videoWidth) {
      canvas.value.width = v.videoWidth; canvas.value.height = v.videoHeight
      ctx.drawImage(v, 0, 0)
      const img = ctx.getImageData(0, 0, v.videoWidth, v.videoHeight)
      const hit = jsQR(img.data, img.width, img.height)
      if (hit?.data) handle(hit.data, 'qr')
    }
    raf = requestAnimationFrame(loop)
  }
  loop()
}

watch(() => ui.add, a => {
  pasted.value = ''
  if (a) tab.value = a.mode === 'verify' ? 'scan' : 'code'
}, { immediate: true })

async function show() {
  link.value = myInviteLink()
  qr.value = await QRCode.toDataURL(link.value, { margin: 1, width: 480, errorCorrectionLevel: 'M' })
}
watch([() => ui.add, tab], () => {
  stopScan(); busy = false
  if (!ui.add) return
  tab.value === 'scan' ? startScan() : tab.value === 'code' && show()
}, { immediate: true, flush: 'post' })
onBeforeUnmount(stopScan)

async function share() {
  try {
    if (navigator.share) await navigator.share({ title: 'Ripplo', text: link.value })
    else { await navigator.clipboard.writeText(link.value); toast(t('copied')) }
  } catch {}
}
async function paste() {
  try { pasted.value = await navigator.clipboard.readText() } catch {}
}
</script>
<template>
  <div v-if="ui.add" class="scrim" @click.self="close">
    <div class="sheet" role="dialog" aria-modal="true" :aria-label="t('addContact')">
      <h3>{{ verify ? t('verifyQr') : t('addContact') }}</h3>
      <div v-if="!verify" class="seg" style="margin-bottom: 16px">
        <button :aria-pressed="tab === 'code'" @click="tab = 'code'">{{ t('myCode') }}</button>
        <button :aria-pressed="tab === 'scan'" @click="tab = 'scan'">{{ t('scan') }}</button>
        <button :aria-pressed="tab === 'paste'" @click="tab = 'paste'">{{ t('pasteLink') }}</button>
      </div>

      <div v-if="tab === 'code'" class="center" style="padding: 0; gap: 12px">
        <img v-if="qr" :src="qr" class="qr" :alt="t('myCode')" />
        <div style="font-weight: 600">{{ state.profile?.name }}</div>
        <div class="mono hint">{{ state.profile?.ripploId }}</div>
        <button class="btn block" @click="share">{{ t('shareLink') }}</button>
      </div>

      <div v-else-if="tab === 'scan'">
        <p v-if="verify">{{ t('scanSafetyHint') }}</p>
        <div class="view"><video ref="video" muted playsinline /><canvas ref="canvas" hidden /></div>
      </div>

      <div v-else>
        <input v-model="pasted" class="field" :placeholder="t('pasteLink')" :aria-label="t('pasteLink')" autocapitalize="off" spellcheck="false" />
        <div class="actions" style="margin-top: 12px">
          <button class="btn ghost" @click="paste">{{ t('paste') }}</button>
          <button class="btn" :disabled="!pasted.trim()" @click="handle(pasted.trim(), 'link')">{{ t('add') }}</button>
        </div>
      </div>

      <button class="btn ghost block" style="margin-top: 16px" @click="close">{{ t('close') }}</button>
    </div>
  </div>
</template>
<style scoped>
.qr { width: min(72vw, 280px); border-radius: 14px; background: #fff; padding: 8px; image-rendering: pixelated; }
.hint { color: var(--text-2); font-size: 13px; }
.view { position: relative; aspect-ratio: 1; border-radius: 22px; overflow: hidden; background: var(--surface); }
.view video { width: 100%; height: 100%; object-fit: cover; }
.view::after { content: ''; position: absolute; inset: 18%; border: 3px solid var(--accent); border-radius: 18px; box-shadow: 0 0 0 100vmax rgba(0, 0, 0, .45); }
</style>
