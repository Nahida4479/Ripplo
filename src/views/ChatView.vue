<script setup>
import { ref, computed, watch, nextTick, onMounted, onBeforeUnmount } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ChevronLeft, Lock, Check, CheckCheck, CloudOff, CircleAlert, Plus, Mic, Send, X, Play, Pause, ShieldAlert } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { loadMessages, markRead, sendText, sendAttachment, retry, verifyNearby, markVerified, MAX_TEXT, MAX_FILE } from '../core/api.js'
import { ui, toast } from '../components/ui.js'
import { t, locale } from '../i18n.js'
import Avatar from '../components/Avatar.vue'

const id = useRoute().params.id
const router = useRouter()
const chat = computed(() => state.chats.find(c => c.id === id))
const contact = computed(() => state.contacts[id])
const name = computed(() => chat.value?.name || contact.value?.name || '')
const isGroup = computed(() => chat.value?.type === 'group')
const msgs = computed(() => state.messages[id] || [])
const text = ref('')
const scroller = ref(null)
const fileIn = ref(null)

const route = computed(() => {
  const n = state.neighbors.find(x => x.card?.id === id)
  return n ? String(n.medium).toUpperCase() : null
})
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
const bars = m => [...m.id].map((c, i) => 6 + ((c.charCodeAt(0) * (i + 3)) % 18)).slice(0, 28)
const dur = s => `${Math.floor((s || 0) / 60)}:${String(Math.round((s || 0) % 60)).padStart(2, '0')}`

function toBottom() { nextTick(() => scroller.value && (scroller.value.scrollTop = scroller.value.scrollHeight)) }
onMounted(async () => { await loadMessages(id); await markRead(id); toBottom() })
watch(() => msgs.value.length, () => { toBottom(); markRead(id) })

async function send() {
  const v = text.value.trim()
  if (!v || v.length > MAX_TEXT) return
  text.value = ''
  try { await sendText(id, v) } catch (e) { toast(e.message) }
}
async function pickFile(e) {
  const f = e.target.files[0]
  e.target.value = ''
  if (!f) return
  if (f.size > MAX_FILE) return toast(t('fileTooBig'))
  try { await sendAttachment(id, f, f.type.startsWith('video') ? 'video' : 'image') } catch (err) { toast(err.message) }
}

const rec = ref(false)
const recSec = ref(0)
let recorder, chunks, tick, cancelled
async function startRec() {
  try {
    const s = await navigator.mediaDevices.getUserMedia({ audio: true })
    recorder = new MediaRecorder(s); chunks = []; cancelled = false
    recorder.ondataavailable = e => chunks.push(e.data)
    recorder.onstop = async () => {
      s.getTracks().forEach(x => x.stop())
      if (cancelled || !chunks.length) return
      const blob = new Blob(chunks, { type: recorder.mimeType })
      if (blob.size > MAX_FILE) return toast(t('fileTooBig'))
      try { await sendAttachment(id, blob, 'voice') } catch (err) { toast(err.message) }
    }
    recorder.start(); rec.value = true; recSec.value = 0
    tick = setInterval(() => recSec.value++, 1000)
  } catch { toast(t('micDenied')) }
}
function stopRec(cancel) {
  cancelled = cancel
  clearInterval(tick); rec.value = false
  if (recorder?.state === 'recording') recorder.stop()
}
onBeforeUnmount(() => rec.value && stopRec(true))

const playing = ref(null)
let audio
function play(m) {
  audio?.pause()
  if (playing.value === m.id) { playing.value = null; return }
  audio = new Audio(m.att.url)
  audio.onended = () => { playing.value = null }
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
        <Avatar :name="name" :size="38" :group="isGroup" />
        <span><b>{{ name }}</b><br /><small>{{ sub }}</small></span>
      </button>
    </header>

    <div v-if="banner" class="banner" :class="banner" role="alert">
      <ShieldAlert :size="20" />
      <div>
        <p>{{ banner === 'red' ? t('conflictWarning') : t('unverifiedWarning') }}</p>
        <div class="bacts">
          <button class="btn sm ghost" @click="ui.add = { mode: 'verify', id }">{{ t('verifyQr') }}</button>
          <button class="btn sm ghost" @click="retryMesh">{{ t('retryMesh') }}</button>
          <button v-if="banner === 'amber'" class="btn sm ghost" @click="sure">{{ t('imSure') }}</button>
        </div>
      </div>
    </div>

    <div ref="scroller" class="log">
      <p class="lock"><Lock :size="13" /> {{ t('encryptedLine') }}</p>
      <template v-for="(m, i) in msgs" :key="m.id">
        <div v-if="showDay(i)" class="day"><span>{{ dayLabel(m.ts) }}</span></div>
        <div class="msg" :class="m.from === 'me' ? 'out' : 'in'">
          <div class="bubble" @click="shown = shown === m.id ? null : m.id">
            <img v-if="m.att?.kind === 'image' && m.att.url" :src="m.att.url" class="media" :alt="t('image')" />
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
          <div v-else-if="m.from === 'me' && (shown === m.id || m.status === 'delivered')" class="st">{{ statusLabel(m) }}</div>
        </div>
      </template>
    </div>

    <footer class="comp">
      <template v-if="rec">
        <button class="icon-btn" :aria-label="t('cancel')" @click="stopRec(true)"><X :size="22" /></button>
        <span class="recd"><i /> {{ dur(recSec) }}</span>
        <button class="send" :aria-label="t('send')" @click="stopRec(false)"><Send :size="20" /></button>
      </template>
      <template v-else>
        <button class="icon-btn" :aria-label="t('attach')" @click="fileIn.click()"><Plus :size="22" /></button>
        <input ref="fileIn" type="file" accept="image/*,video/*" hidden @change="pickFile" />
        <div class="box">
          <textarea v-model="text" rows="1" :placeholder="t('message')" :aria-label="t('message')" @keydown.enter.exact.prevent="send" @input="e => { e.target.style.height = 'auto'; e.target.style.height = e.target.scrollHeight + 'px' }" />
          <small v-if="text.length >= 900" :class="{ over: text.length >= MAX_TEXT }">{{ text.length }}/{{ MAX_TEXT }}</small>
        </div>
        <button v-if="text.trim()" class="send" :aria-label="t('send')" @click="send"><Send :size="20" /></button>
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
.st, .oor { font-size: 11px; color: var(--text-2); margin: 2px 4px; display: flex; gap: 6px; align-items: center; }
.oor { color: var(--danger); }
.comp { display: flex; align-items: flex-end; gap: 6px; padding: 8px 0 calc(var(--sab) + 8px); }
.box { flex: 1; display: flex; align-items: flex-end; gap: 6px; background: var(--surface); border: 1px solid var(--border); border-radius: 22px; padding: 4px 14px; }
.box textarea { flex: 1; border: 0; background: none; resize: none; outline: none; max-height: 120px; padding: 8px 0; line-height: 1.35; }
.box small { color: var(--text-2); font-size: 11px; padding-bottom: 10px; }
.box small.over { color: var(--danger); }
.send { width: 44px; height: 44px; border-radius: 50%; background: var(--accent); color: var(--on-accent); display: grid; place-items: center; flex: none; }
.recd { flex: 1; display: flex; align-items: center; gap: 8px; }
.recd i { width: 10px; height: 10px; border-radius: 50%; background: var(--danger); }
</style>
