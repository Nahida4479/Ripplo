<script setup>
import { ref, watch, onBeforeUnmount, computed, nextTick } from 'vue'
import QRCode from 'qrcode'
import { startScanner } from '../lib/scanner.js'
import { splitLink, createAssembler } from '../lib/qrparts.js'
import { useRouter } from 'vue-router'
import { state } from '../core/state.js'
import { myInviteLink, addContactFromLink, verifyByQr } from '../core/api.js'
import { ui, toast } from './ui.js'
import { webLink } from '../crypto/identity.js'
import { t, locale } from '../i18n.js'

const router = useRouter()
const tab = ref('code')
const qr = ref('')
const frame = ref(0)
const frameCount = ref(0)
const progress = ref('')
const link = ref('')
const pasted = ref('')
const video = ref(null)
const canvas = ref(null)
let stopper, busy = false, frames = [], cycle, assembler = createAssembler()
const verify = computed(() => ui.add?.mode === 'verify')

function stopScan() {
  stopper?.()
  stopper = null
}
function stopCycle() {
  clearInterval(cycle)
  cycle = null
}
function close() { stopScan(); stopCycle(); ui.add = null }

async function handle(raw, via) {
  if (busy) return
  const part = assembler.add(raw)
  let text = raw
  if (part) {
    if (part.have) progress.value = `${part.have}/${part.total}`
    if (part.bad) { toast(t('err_bad_checksum')); progress.value = '' }
    if (!part.link) return
    text = part.link
    progress.value = ''
  }
  busy = true
  try {
    if (verify.value) {
      const ok = await verifyByQr(ui.add.id, text)
      if (ok && navigator.vibrate) navigator.vibrate(30)
      toast(ok ? t('verifiedOk') : t('verifyMismatch'))
      if (!ok) { setTimeout(() => { busy = false }, 1500); return }
      close()
    } else {
      const c = await addContactFromLink(text, via)
      if (navigator.vibrate) navigator.vibrate(30)
      toast(t('added'))
      close(); router.push('/contact/' + c.id)
    }
  } catch (e) {
    toast(t('err_' + (e.code || 'bad_link')))
    setTimeout(() => { busy = false }, 1500)
  }
}

async function startScan() {
  await nextTick()
  if (!video.value || !canvas.value) return
  try {
    stopper = await startScanner(video.value, canvas.value, text => handle(text, 'qr'))
  } catch { toast(t('cameraDenied')) }
}

watch(() => ui.add, a => {
  pasted.value = ''
  if (a) tab.value = a.mode === 'verify' ? 'scan' : 'code'
}, { immediate: true })

async function show() {
  link.value = myInviteLink()
  const parts = splitLink(link.value)
  frames = await Promise.all(parts.map((p) => QRCode.toDataURL(p, { margin: 2, width: 560, errorCorrectionLevel: 'L' })))
  frameCount.value = frames.length
  frame.value = 0
  qr.value = frames[0]
  stopCycle()
  cycle = setInterval(() => {
    frame.value = (frame.value + 1) % frames.length
    qr.value = frames[frame.value]
  }, 700)
}
watch([() => ui.add, tab], () => {
  stopScan(); stopCycle(); busy = false; progress.value = ''; assembler = createAssembler()
  if (!ui.add) return
  tab.value === 'scan' ? startScan() : tab.value === 'code' && show()
}, { immediate: true, flush: 'post' })
onBeforeUnmount(() => { stopScan(); stopCycle() })

async function share() {
  try {
    const text = `${t('inviteShareText')}\n${webLink(link.value, locale.value)}`
    if (navigator.share) await navigator.share({ title: 'Ripplo', text })
    else { await navigator.clipboard.writeText(text); toast(t('copied')) }
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
        <div v-if="frameCount > 1" class="dots" aria-hidden="true"><i v-for="n in frameCount" :key="n" :class="{ on: n - 1 === frame }" /></div>
        <p v-if="frameCount > 1" class="hint" style="margin: 0; text-align: center">{{ t('codeFramesHint') }}</p>
        <div style="font-weight: 600">{{ state.profile?.name }}</div>
        <div class="mono hint">{{ state.profile?.ripploId }}</div>
        <button class="btn block" @click="share">{{ t('inviteFriend') }}</button>
        <p class="hint" style="margin: 0; text-align: center">{{ t('inviteHint') }}</p>
      </div>

      <div v-else-if="tab === 'scan'">
        <p v-if="verify">{{ t('scanSafetyHint') }}</p>
        <div class="view"><video ref="video" muted playsinline /><canvas ref="canvas" hidden /><span v-if="progress" class="prog">{{ t('scanParts', { n: progress }) }}</span></div>
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
.dots { display: flex; gap: 6px; }
.dots i { width: 8px; height: 8px; border-radius: 50%; background: var(--surface-2); }
.dots i.on { background: var(--accent); }
.prog { position: absolute; left: 50%; bottom: 14px; transform: translateX(-50%); z-index: 1; padding: 4px 12px; border-radius: 999px; background: rgba(0, 0, 0, .6); color: #fff; font-size: 13px; font-variant-numeric: tabular-nums; }
.view { position: relative; aspect-ratio: 1; border-radius: 22px; overflow: hidden; background: var(--surface); }
.view video { width: 100%; height: 100%; object-fit: cover; }
.view::after { content: ''; position: absolute; inset: 18%; border: 3px solid var(--accent); border-radius: 18px; box-shadow: 0 0 0 100vmax rgba(0, 0, 0, .45); }
</style>
