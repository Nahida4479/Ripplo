<script setup>
import { computed, ref, watch, onBeforeUnmount } from 'vue'
import { Phone, PhoneOff, Mic, MicOff } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { acceptCall, hangUp, setMuted } from '../core/api.js'
import { startRing, stopRing } from '../services/ringtone.js'
import { t } from '../i18n.js'
import Avatar from './Avatar.vue'

const call = computed(() => state.call)
const peer = computed(() => state.contacts[call.value?.peer])
const now = ref(Date.now())
const tick = setInterval(() => { now.value = Date.now() }, 1000)
const elapsed = computed(() => (call.value?.startedAt ? Math.max(0, Math.floor((now.value - call.value.startedAt) / 1000)) : 0))
const clock = computed(() => `${Math.floor(elapsed.value / 60)}:${String(elapsed.value % 60).padStart(2, '0')}`)
const ringing = computed(() => call.value?.status === 'ringing')
const incoming = computed(() => ringing.value && call.value.dir === 'in')
const status = computed(() => {
  const c = call.value
  if (!c) return ''
  if (c.status === 'ended') return t('call_' + c.reason)
  if (c.status === 'active') return clock.value
  if (c.status === 'connecting') return t('callConnecting')
  return t(c.dir === 'in' ? 'incomingCall' : 'calling')
})

watch(incoming, (on) => (on ? startRing() : stopRing()), { immediate: true })
onBeforeUnmount(() => { clearInterval(tick); stopRing() })
</script>
<template>
  <div v-if="call" class="call" role="dialog" aria-modal="true" :aria-label="peer?.name">
    <div class="who">
      <Avatar :name="peer?.name" :photo="peer?.avatar" :size="112" />
      <h2>{{ peer?.name }}</h2>
      <p role="status">{{ status }}</p>
    </div>
    <div v-if="call.status !== 'ended'" class="acts">
      <template v-if="incoming">
        <button class="round bad" :aria-label="t('callDecline')" @click="hangUp"><PhoneOff :size="28" /></button>
        <button class="round good" :aria-label="t('callAnswer')" @click="acceptCall"><Phone :size="28" /></button>
      </template>
      <template v-else>
        <button class="round" :class="{ on: call.muted }" :aria-label="t(call.muted ? 'callUnmute' : 'callMute')" :aria-pressed="call.muted" @click="setMuted(!call.muted)">
          <component :is="call.muted ? MicOff : Mic" :size="26" />
        </button>
        <button class="round bad" :aria-label="t('callEnd')" @click="hangUp"><PhoneOff :size="28" /></button>
      </template>
    </div>
  </div>
</template>
<style scoped>
.call { position: fixed; inset: 0; z-index: 70; background: var(--bg); display: flex; flex-direction: column; justify-content: space-between; align-items: center; padding: calc(var(--sat, 0px) + 72px) 24px calc(var(--sab, 0px) + 56px); }
.who { display: flex; flex-direction: column; align-items: center; gap: 8px; }
.who h2 { margin: 12px 0 0; font-size: 26px; }
.who p { margin: 0; color: var(--text-2); font-size: 16px; font-variant-numeric: tabular-nums; }
.acts { display: flex; gap: 40px; }
.round { width: 68px; height: 68px; border-radius: 50%; display: grid; place-items: center; background: var(--surface-2); color: var(--text); }
.round.on { background: var(--text); color: var(--bg); }
.round.bad { background: var(--danger); color: #fff; }
.round.good { background: var(--ok); color: #fff; }
</style>
