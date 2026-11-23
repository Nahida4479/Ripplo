<script setup>
import { ref, computed, watch, nextTick, onMounted, onBeforeUnmount } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ChevronLeft, Phone, Reply, Lock, Check, CheckCheck, CloudOff, CircleAlert, Plus, Mic, Send, X, Play, Pause, ShieldAlert } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { startCall, sendTyping, unsendMessage, loadMessages, markRead, sendText, sendAttachment, retry, verifyNearby, markVerified, nodeOf, MAX_TEXT, MAX_FILE } from '../core/api.js'
import { ui, toast } from '../components/ui.js'
import { t, locale } from '../i18n.js'
import { refreshRange } from '../services/rangeRefresh.js'
import Avatar from '../components/Avatar.vue'

const id = useRoute().params.id
const router = useRouter()
const chat = computed(() => state.chats.find(c => c.id === id))
const contact = computed(() => state.contacts[id])
const name = computed(() => chat.value?.name || contact.value?.name || '')
const isGroup = computed(() => chat.value?.type === 'group')
const mediaLocked = computed(() => !isGroup.value && !!contact.value && contact.value.addedVia !== 'incoming' && !contact.value.cardAck)
const fail = e => toast(e.code === 'media_locked' ? t('err_media_locked') : e.message)
const canCall = computed(() => !isGroup.value && !!contact.value && !contact.value.request && (contact.value.addedVia !== 'incoming' || !!contact.value.cardSent))
async function call() { try { await startCall(id) } catch (e) { toast(t('err_' + (e.code || 'call_unsupported'))) } }
const msgs = computed(() => state.messages[id] || [])
const text = ref('')
const scroller = ref(null)
const fileIn = ref(null)

const route = computed(() => {
  // Match by card id or by the contact's node id, so a neighbour without a card yet still counts.
  const node = nodeOf(id)
  const known = state.contacts[id]?.node
  const n = state.neighbors.find(x => x.card?.id === id || (node && x.node === node) || (known && x.node === known))
  if (n) return String(n.medium).toUpperCase()
  // Not a direct neighbour, but reachable over relays: show the hop count from recent discovery.
  const p = state.people.find(x => x.id === id)
  return p && Date.now() - p.seenAt < 10 * 60e3 ? t('hops', { n: p.hops }) : null
})
// Refresh the range shown in the header as soon as the chat opens (rate-limited in rangeRefresh.js).
onMounted(() => { refreshRange() })
const sub = computed(() => {
  if (isGroup.value) return t('members', { n: chat.value.members?.length || 0 })
  const ok = contact.value && contact.value.verification !== 'none'
  return (ok ? '✓ ' + t('verified') : '⚠ ' + t('notVerified')) + ' · ' + (route.value || t('outOfRange'))
})
const banner = computed(() => !isGroup.value && contact.value && (contact.value.conflict ? 'red' : contact.value.verification === 'none' ? 'amber' : null))

const day = ts => new Date(ts).toDateString()
const dayLabel = ts => new Date(ts).toLocaleDateString(locale.value, { weekday: 'long', day: 'numeric', month: 'long' })
const time = ts => new Date(ts).toLocaleTimeString(locale.value, { hour: '2-digit', minute: '2-digit' })
const showDay = i => i === 0 || day(msgs.value[i - 1].ts) !== day(msgs.value[i].ts)
const bars = m => m.att?.wave?.length
  ? m.att.wave.map(v => 4 + Math.round(v / 255 * 22))
  : [...m.id].map((c, i) => 6 + ((c.charCodeAt(0) * (i + 3)) % 18)).slice(0, 28)
const dur = s => `${Math.floor((s || 0) / 60)}:${String(Math.round((s || 0) % 60)).padStart(2, '0')}`

function toBottom() { nextTick(() => scroller.value && (scroller.value.scrollTop = scroller.value.scrollHeight)) }
onMounted(async () => { await loadMessages(id); await markRead(id); toBottom() })
const typers = computed(() => state.typing[id] || [])
watch(() => msgs.value.length, () => { toBottom(); markRead(id) })
watch(() => typers.value.length, n => n && toBottom())

const replyTo = ref(null)
const staged = ref([])
const MAX_STAGED = 10
const authorOf = m => (m.from === 'me' ? t('you') : state.contacts[m.from]?.name || 'Ripplo')
const whoName = who => (who === state.profile?.ripploId ? t('you') : state.contacts[who]?.name || 'Ripplo')
const kindLabel = kind => t(kind === 'video' ? 'videoMessage' : kind === 'voice' ? 'voiceMessage' : 'photoMessage')
const snippet = m => m.text || kindLabel(m.att?.kind)

function unstageAll() {
  for (const s of staged.value) URL.revokeObjectURL(s.url)
  staged.value = []
}
function unstage(i) {
  URL.revokeObjectURL(staged.value[i].url)
  staged.value.splice(i, 1)
}
async function send() {
  const v = text.value.trim()
  if ((!v && !staged.value.length) || v.length > MAX_TEXT) return
  const items = staged.value
  const to = replyTo.value?.id
  staged.value = []
  replyTo.value = null
  text.value = ''
  try {
    if (!items.length) return await sendText(id, v, to)
    for (let i = 0; i < items.length; i++) {
      const last = i === items.length - 1
      await sendAttachment(id, items[i].file, items[i].kind, { ...(last && v && { caption: v }), ...(i === 0 && to && { replyTo: to }) })
      URL.revokeObjectURL(items[i].url)
    }
  } catch (e) {
    items.forEach(s => URL.revokeObjectURL(s.url))
    fail(e)
  }
}
function pickFile(e) {
  const files = [...e.target.files]
  e.target.value = ''
  for (const f of files) {
    if (staged.value.length >= MAX_STAGED) break
    if (f.size > MAX_FILE) { toast(t('fileTooBig')); continue }
    staged.value.push({ file: f, kind: f.type.startsWith('video') ? 'video' : 'image', url: URL.createObjectURL(f) })
  }
}
onBeforeUnmount(unstageAll)

const SWIPE = 56
const offset = ref({ id: null, x: 0, rest: true })
let drag = null
let swiped = false
function confirmUnsend(m) {
  ui.confirm = { title: t('unsendTitle'), text: t('unsendText'), ok: t('unsend'), danger: true, onOk: () => unsendMessage(id, m.id).catch(fail) }
}
function onDown(e, m) {
  if (e.pointerType === 'mouse' && e.button !== 0) return
  drag = { m, x: e.clientX, y: e.clientY, locked: false, el: e.currentTarget, pid: e.pointerId, press: null }
  if (m.from === 'me') {
    const d = drag
    d.press = setTimeout(() => {
      if (drag === d && !d.locked) { swiped = true; drag = null; if (navigator.vibrate) navigator.vibrate(15); confirmUnsend(m) }
    }, 550)
  }
}
function onMove(e) {
  if (!drag) return
  const dx = e.clientX - drag.x
  const dy = e.clientY - drag.y
  if (Math.abs(dx) > 8 || Math.abs(dy) > 8) clearTimeout(drag.press)
  if (!drag.locked) {
    if (Math.abs(dy) > 12 && Math.abs(dy) > Math.abs(dx)) { drag = null; return }
    if (Math.abs(dx) < 12) return
    drag.locked = true
    try { drag.el.setPointerCapture(drag.pid) } catch {}
  }
  offset.value = { id: drag.m.id, x: Math.max(-72, Math.min(72, dx)), rest: false }
}
function endDrag(commit) {
  if (!drag) return
  clearTimeout(drag.press)
  const hit = drag.locked && commit && Math.abs(offset.value.x) >= SWIPE
  if (drag.locked) { swiped = true; setTimeout(() => { swiped = false }, 80) }
  if (hit) { replyTo.value = drag.m; if (navigator.vibrate) navigator.vibrate(12) }
  offset.value = { id: drag.m.id, x: 0, rest: true }
  drag = null
}
function toggleStatus(m) {
  if (!swiped) shown.value = shown.value === m.id ? null : m.id
}
const viewer = ref(null)
function openImage(m) {
  if (!swiped) viewer.value = m
}
function jump(mid) {
  const el = document.getElementById('m-' + mid)
  if (!el) return
  el.scrollIntoView({ block: 'center', behavior: 'smooth' })
  el.classList.add('flash')
  setTimeout(() => el.classList.remove('flash'), 1200)
}

const rec = ref(false)
const recSec = ref(0)
const live = ref([])
const MIMES = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus', 'audio/webm']
const WAVE_BARS = 40
let recorder, chunks, tick, cancelled, actx, meter, samples, startedAt
function summarize() {
  if (!samples.length) return { peak: null, wave: undefined }
  const peak = Math.max(...samples)
  const size = samples.length / WAVE_BARS
  const wave = Array.from({ length: Math.min(WAVE_BARS, samples.length) }, (_, i) => {
    const part = samples.slice(Math.floor(i * Math.max(size, 1)), Math.max(Math.floor((i + 1) * Math.max(size, 1)), Math.floor(i * Math.max(size, 1)) + 1))
    return Math.round(Math.max(...part) / (peak || 1) * 255)
  })
  return { peak, wave }
}
function stopMeter() {
  clearInterval(meter)
  actx?.close().catch(() => {})
  actx = null
}
async function startRec() {
  if (mediaLocked.value) return toast(t('err_media_locked'))
  try {
    const s = await navigator.mediaDevices.getUserMedia({ audio: true })
    const mimeType = MIMES.find(m => MediaRecorder.isTypeSupported(m))
    recorder = new MediaRecorder(s, mimeType ? { mimeType } : undefined); chunks = []; cancelled = false; samples = []; live.value = []
    try {
      actx = new AudioContext()
      await actx.resume()
      const an = actx.createAnalyser()
      an.fftSize = 512
      actx.createMediaStreamSource(s).connect(an)
      const buf = new Uint8Array(an.fftSize)
      meter = setInterval(() => {
        an.getByteTimeDomainData(buf)
        let peak = 0
        for (const v of buf) peak = Math.max(peak, Math.abs(v - 128) / 128)
        samples.push(peak)
        live.value = [...live.value, 3 + Math.round(Math.min(1, peak * 2.5) * 22)].slice(-32)
      }, 100)
    } catch { actx = null }
    recorder.ondataavailable = e => { if (e.data?.size) chunks.push(e.data) }
    recorder.onstop = async () => {
      s.getTracks().forEach(x => x.stop())
      stopMeter()
      if (cancelled || !chunks.length) return
      const seconds = Math.max(1, Math.round((Date.now() - startedAt) / 1000))
      const blob = new Blob(chunks, { type: recorder.mimeType || mimeType || 'audio/webm' })
      const { peak, wave } = summarize()
      if (blob.size < 800 || (peak !== null && peak < 0.02)) return toast(t('noSound'))
      if (blob.size > MAX_FILE) return toast(t('fileTooBig'))
      try { await sendAttachment(id, blob, 'voice', { duration: seconds, wave }) } catch (err) { fail(err) }
    }
    recorder.start(250); startedAt = Date.now(); rec.value = true; recSec.value = 0
    tick = setInterval(() => recSec.value++, 1000)
  } catch { toast(t('micDenied')) }
}
function stopRec(cancel) {
  cancelled = cancel
  clearInterval(tick); rec.value = false
  if (recorder?.state === 'recording') recorder.stop()
  else stopMeter()
}
onBeforeUnmount(() => rec.value && stopRec(true))

const playing = ref(null)
let audio
function play(m) {
  audio?.pause()
  if (playing.value === m.id) { playing.value = null; return }
  audio = new Audio(m.att.url)
  audio.onended = () => { playing.value = null }
  audio.onerror = () => { playing.value = null; toast(t('playFailed')) }
  audio.play().catch(() => toast(t('playFailed')))
  playing.value = m.id
}
onBeforeUnmount(() => audio?.pause())

const statusLabel = m => m.status === 'delivered' && m.hops > 1 ? t('viaPhones', { n: m.hops - 1 }) : t('status_' + m.status)
const shown = ref(null)
async function retryMesh() { toast((await verifyNearby(id)) ? t('verifiedOk') : t('verifyFailed')) }
function sure() { ui.confirm = { title: t('imSure'), text: t('imSureConfirm'), ok: t('confirm'), onOk: () => markVerified(id) } }
</script>
<template>
  <main class="page full">
    <header class="hdr top">
      <button class="icon-btn" :aria-label="t('back')" @click="router.back()"><ChevronLeft :size="24" /></button>
      <button class="who" :aria-label="t('contactInfo')" :disabled="isGroup" @click="router.push('/contact/' + id)">
        <Avatar :name="name" :photo="contact?.avatar" :size="38" :group="isGroup" />
        <span><b>{{ name }}</b><br /><small>{{ sub }}</small></span>
      </button>
      <button v-if="canCall" class="icon-btn" style="margin-left: auto" :aria-label="t('callAction')" :disabled="!!state.call" @click="call"><Phone :size="22" /></button>
    </header>

    <div v-if="banner" class="banner" :class="banner" role="alert">
      <ShieldAlert :size="20" />
      <div>
        <p>{{ banner === 'red' ? t('conflictWarning') : t('unverifiedWarning') }}</p>
        <p v-if="contact?.peerVerified">{{ t('peerVerified', { name: contact.name, method: t('method_' + contact.peerVerified.level) }) }}</p>
        <div class="bacts">
          <button class="btn sm ghost" @click="ui.add = { mode: 'verify', id }">{{ t('verifyQr') }}</button>
          <button class="btn sm ghost" @click="retryMesh">{{ t('retryMesh') }}</button>
          <button v-if="banner === 'amber'" class="btn sm ghost" @click="sure">{{ t('imSure') }}</button>
        </div>
      </div>
    </div>

    <div ref="scroller" class="log">
      <p v-if="state.devCrypto" class="lock" style="color: var(--danger); font-weight: 600"><ShieldAlert :size="13" /> {{ t('devCryptoWarn') }}</p>
      <p v-else class="lock"><Lock :size="13" /> {{ t('encryptedLine') }}</p>
      <template v-for="(m, i) in msgs" :key="m.id">
        <div v-if="showDay(i)" class="day"><span>{{ dayLabel(m.ts) }}</span></div>
        <p v-if="m.from === 'system'" class="lock sys">{{ m.text }}</p>
        <div v-else :id="'m-' + m.id" class="msg" :class="m.from === 'me' ? 'out' : 'in'">
          <Reply v-if="offset.id === m.id && offset.x" class="swipe-ic" :class="{ right: offset.x < 0 }" :style="{ opacity: Math.min(1, Math.abs(offset.x) / SWIPE) }" :size="20" />
          <div
            class="bubble" :class="{ rest: offset.id === m.id && offset.rest }"
            :style="offset.id === m.id && offset.x ? { transform: `translateX(${offset.x}px)` } : null"
            @click="toggleStatus(m)" @pointerdown="onDown($event, m)" @pointermove="onMove" @pointerup="endDrag(true)" @pointercancel="endDrag(false)" @contextmenu.prevent="m.from === 'me' && confirmUnsend(m)"
          >
            <button v-if="m.re" class="quote" @click.stop="jump(m.re.mid)">
              <b>{{ whoName(m.re.who) }}</b>
              <span>{{ m.re.text || kindLabel(m.re.kind) }}</span>
            </button>
            <img v-if="m.att?.kind === 'image' && m.att.url" :src="m.att.url" class="media zoomable" :alt="t('image')" @click.stop="openImage(m)" />
            <video v-else-if="m.att?.kind === 'video' && m.att.url" :src="m.att.url" class="media" controls preload="metadata" />
            <div v-else-if="m.att?.kind === 'voice'" class="voice">
              <button class="pl" :aria-label="t('play')" @click.stop="play(m)"><component :is="playing === m.id ? Pause : Play" :size="18" /></button>
              <span class="wave"><i v-for="(h, k) in bars(m)" :key="k" :style="{ height: h + 'px' }" /></span>
              <small>{{ dur(m.att.duration) }}</small>
            </div>
            <span v-if="m.text" class="txt">{{ m.text }}</span>
            <span class="meta">
              {{ time(m.ts) }}
              <template v-if="m.from === 'me'">
                <Lock v-if="m.status === 'encrypting'" class="spin" :size="12" />
                <span v-else-if="m.status === 'sending'" class="tk"><Check :size="14" /><template v-if="m.att && m.progress != null">{{ Math.round(m.progress * 100) }}%</template></span>
                <CheckCheck v-else-if="m.status === 'delivered'" :size="14" />
                <CircleAlert v-else-if="m.status === 'failed'" :size="14" />
              </template>
            </span>
          </div>
          <div v-if="m.from === 'me' && (m.status === 'out_of_range' || m.status === 'failed')" class="oor">
            <CloudOff :size="14" /> {{ m.status === 'failed' ? t('status_failed') : t('outOfMeshRange') }}
            <button class="btn sm" @click="retry(m.id)">{{ t('retry') }}</button>
          </div>
          <div v-else-if="m.from === 'me' && (shown === m.id || m.status === 'delivered')" class="st">
            {{ statusLabel(m) }}
            <button v-if="shown === m.id" class="btn sm ghost" @click="confirmUnsend(m)">{{ t('unsend') }}</button>
          </div>
        </div>
      </template>
      <div v-if="typers.length" class="msg in">
        <div class="bubble dots" role="status" :aria-label="t('typing')"><i /><i /><i /></div>
      </div>
    </div>

    <div v-if="viewer" class="viewer" role="dialog" aria-modal="true" @click.self="viewer = null">
      <button class="icon-btn close" :aria-label="t('close')" @click="viewer = null"><X :size="24" /></button>
      <img :src="viewer.att.url" alt="" />
    </div>
    <div v-if="replyTo" class="replybar">
      <Reply :size="18" />
      <div class="rt"><b>{{ authorOf(replyTo) }}</b><span>{{ snippet(replyTo) }}</span></div>
      <button class="icon-btn" :aria-label="t('cancel')" @click="replyTo = null"><X :size="20" /></button>
    </div>
    <div v-if="staged.length" class="staged">
      <div v-for="(s, i) in staged" :key="s.url" class="thumb">
        <img v-if="s.kind === 'image'" :src="s.url" alt="" />
        <video v-else :src="s.url" muted playsinline preload="metadata" />
        <button class="rm" :aria-label="t('cancel')" @click="unstage(i)"><X :size="14" /></button>
      </div>
    </div>
    <footer class="comp">
      <template v-if="rec">
        <button class="icon-btn" :aria-label="t('cancel')" @click="stopRec(true)"><X :size="22" /></button>
        <span class="recd"><i /> {{ dur(recSec) }}<span class="wave live" aria-hidden="true"><i v-for="(h, k) in live" :key="k" :style="{ height: h + 'px' }" /></span></span>
        <button class="send" :aria-label="t('send')" @click="stopRec(false)"><Send :size="20" /></button>
      </template>
      <template v-else>
        <button class="icon-btn" :aria-label="t('attach')" @click="mediaLocked ? toast(t('err_media_locked')) : fileIn.click()"><Plus :size="22" /></button>
        <input ref="fileIn" type="file" accept="image/*,video/*" multiple hidden @change="pickFile" />
        <div class="box">
          <textarea v-model="text" rows="1" :placeholder="t('message')" :aria-label="t('message')" @keydown.enter.exact.prevent="send" @input="e => { e.target.style.height = 'auto'; e.target.style.height = e.target.scrollHeight + 'px'; if (text.trim()) sendTyping(id) }" />
          <small v-if="text.length >= 900" :class="{ over: text.length >= MAX_TEXT }">{{ text.length }}/{{ MAX_TEXT }}</small>
        </div>
        <button v-if="text.trim() || staged.length" class="send" :aria-label="t('send')" @click="send"><Send :size="20" /></button>
        <button v-else class="icon-btn" :aria-label="t('recordVoice')" @click="startRec"><Mic :size="22" /></button>
      </template>
    </footer>
  </main>
</template>
<style scoped>
.top { padding-bottom: 4px; }
.who { display: flex; align-items: center; gap: 10px; text-align: left; min-width: 0; }
.who small { color: var(--text-2); font-size: 12px; }
.banner { display: flex; gap: 10px; padding: 10px 12px; margin: 4px 0; border-radius: 14px; font-size: 13px; background: color-mix(in srgb, var(--warn) 16%, transparent); color: var(--warn); }
.banner.red { background: color-mix(in srgb, var(--danger) 16%, transparent); color: var(--danger); }
.banner p { margin: 0 0 8px; color: var(--text); }
.bacts { display: flex; gap: 6px; flex-wrap: wrap; }
.log { flex: 1; overflow-y: auto; margin: 0 -16px; padding: 8px 16px; display: flex; flex-direction: column; gap: 4px; }
.lock { align-self: center; text-align: center; font-size: 12px; color: var(--text-2); margin: 4px 0 8px; }
.sys { color: var(--warn); margin: 8px 0; }
.day { align-self: center; margin: 8px 0; }
.day span { background: var(--surface-2); color: var(--text-2); font-size: 12px; padding: 3px 10px; border-radius: 999px; }
.msg { display: flex; flex-direction: column; max-width: 78%; }
.msg.out { align-self: flex-end; align-items: flex-end; }
.msg.in { align-self: flex-start; }
.bubble { padding: 8px 12px; border-radius: 18px; background: var(--surface-2); position: relative; overflow-wrap: anywhere; white-space: pre-wrap; }
.out .bubble { background: var(--accent); color: var(--on-accent); border-bottom-right-radius: 6px; }
.in .bubble { border-bottom-left-radius: 6px; }
.meta { float: right; margin: 6px 0 -4px 10px; font-size: 11px; opacity: .75; display: inline-flex; gap: 3px; align-items: center; }
.spin { animation: spin 1.2s linear infinite; }
.tk { display: inline-flex; align-items: center; gap: 2px; }
.media { display: block; max-width: 240px; max-height: 240px; border-radius: 14px; margin-bottom: 4px; }
.voice { display: flex; align-items: center; gap: 8px; min-width: 190px; }
.pl { width: 34px; height: 34px; border-radius: 50%; display: grid; place-items: center; background: currentColor; flex: none; }
.pl svg { color: var(--surface-2); }
.out .pl svg { color: var(--accent); }
.wave { display: flex; align-items: center; gap: 2px; flex: 1; }
.wave i { width: 3px; border-radius: 2px; background: currentColor; opacity: .7; }
.zoomable { cursor: zoom-in; }
.viewer { position: fixed; inset: 0; z-index: 60; background: rgba(0, 0, 0, .92); display: grid; place-items: center; padding: calc(var(--sat, 0px) + 56px) 12px calc(var(--sab, 0px) + 12px); }
.viewer img { max-width: 100%; max-height: 100%; border-radius: 8px; }
.viewer .close { position: absolute; top: calc(var(--sat, 0px) + 8px); right: 8px; color: #fff; }
.msg { position: relative; touch-action: pan-y; }
.bubble { touch-action: pan-y; user-select: none; }
.dots { display: flex; gap: 4px; align-items: center; height: 36px; padding: 0 14px; }
.dots i { width: 7px; height: 7px; border-radius: 50%; background: var(--text-2); animation: dot 1.2s infinite ease-in-out; }
.dots i:nth-child(2) { animation-delay: .15s; }
.dots i:nth-child(3) { animation-delay: .3s; }
@keyframes dot { 0%, 60%, 100% { opacity: .3; transform: translateY(0); } 30% { opacity: 1; transform: translateY(-4px); } }
@media (prefers-reduced-motion: reduce) { .dots i { animation: none; opacity: .6; } }
.bubble.rest { transition: transform .18s ease; }
.swipe-ic { position: absolute; top: 50%; left: -30px; transform: translateY(-50%); color: var(--text-2); }
.swipe-ic.right { left: auto; right: -30px; }
.msg.flash .bubble { animation: flash 1.2s ease; }
@keyframes flash { 0%, 60% { box-shadow: 0 0 0 3px var(--accent); } 100% { box-shadow: 0 0 0 3px transparent; } }
.quote { display: block; width: 100%; text-align: left; margin: 0 0 6px; padding: 4px 8px; border-left: 3px solid currentColor; border-radius: 6px; background: color-mix(in srgb, currentColor 12%, transparent); font-size: 12px; white-space: normal; }
.quote b { display: block; opacity: .85; }
.quote span { display: block; opacity: .75; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.replybar { display: flex; align-items: center; gap: 8px; padding: 6px 10px; margin-bottom: 4px; border-radius: 14px; background: var(--surface); border: 1px solid var(--border); color: var(--text-2); }
.replybar .rt { flex: 1; min-width: 0; font-size: 12px; }
.replybar .rt b { display: block; color: var(--text); }
.replybar .rt span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.staged { display: flex; gap: 8px; overflow-x: auto; padding: 6px 0; }
.thumb { position: relative; flex: none; width: 64px; height: 64px; border-radius: 12px; overflow: hidden; background: var(--surface-2); }
.thumb img, .thumb video { width: 100%; height: 100%; object-fit: cover; display: block; }
.thumb .rm { position: absolute; top: 3px; right: 3px; width: 20px; height: 20px; border-radius: 50%; display: grid; place-items: center; background: rgba(0, 0, 0, .6); color: #fff; }
.st, .oor { font-size: 11px; color: var(--text-2); margin: 2px 4px; display: flex; gap: 6px; align-items: center; }
.oor { color: var(--danger); }
.comp { display: flex; align-items: flex-end; gap: 6px; padding: 8px 0 calc(var(--sab) + 8px); }
.box { flex: 1; display: flex; align-items: flex-end; gap: 6px; background: var(--surface); border: 1px solid var(--border); border-radius: 22px; padding: 4px 14px; }
.box textarea { flex: 1; border: 0; background: none; resize: none; outline: none; max-height: 120px; padding: 8px 0; line-height: 1.35; }
.box small { color: var(--text-2); font-size: 11px; padding-bottom: 10px; }
.box small.over { color: var(--danger); }
.send { width: 44px; height: 44px; border-radius: 50%; background: var(--accent); color: var(--on-accent); display: grid; place-items: center; flex: none; }
.recd { flex: 1; display: flex; align-items: center; gap: 8px; }
.recd .live { flex: 1; justify-content: flex-end; height: 28px; color: var(--accent); }
.recd .live i { width: 3px; height: auto; border-radius: 2px; background: currentColor; }
.recd > i { width: 10px; height: 10px; border-radius: 50%; background: var(--danger); }
</style>
