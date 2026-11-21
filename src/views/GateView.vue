<script setup>
import { ref, computed, onMounted } from 'vue'
import { Bluetooth, Wifi, Bell, Mic, BatteryCharging, Check } from 'lucide-vue-next'
import { checkPermissions, requestPermissions, allGranted } from '../services/permissions.js'
import { mesh } from '../mesh/bridge.js'
import { t } from '../i18n.js'

const emit = defineEmits(['granted'])
const perms = ref({})
const all = [['bluetooth', Bluetooth, 'permBluetooth'], ['wifi', Wifi, 'permWifi'], ['notifications', Bell, 'permNotifications'], ['microphone', Mic, 'permMicrophone']]
const rows = computed(() => all.filter(([k]) => k !== 'microphone' || perms.value.microphone))

async function apply(p) { perms.value = p; if (allGranted(p)) emit('granted') }
onMounted(async () => apply(await checkPermissions()))
async function grant() {
  const p = await requestPermissions()
  if (p.battery === 'prompt') await mesh.requestBatteryExemption()
  apply(p.battery === 'prompt' ? await checkPermissions() : p)
}
</script>
<template>
  <main class="page center">
    <img src="/icon.svg" width="88" height="88" alt="Ripplo" />
    <h1 style="margin: 0">Ripplo</h1>
    <p>{{ t('gateWhy') }}</p>
    <div class="card" style="width: 100%; max-width: 420px; text-align: left">
      <div v-for="[k, icon, label] in rows" :key="k" class="row">
        <component :is="icon" :size="22" :stroke-width="1.75" />
        <span class="grow label">{{ t(label) }}</span>
        <span class="chip" :class="perms[k] === 'granted' ? 'ok' : perms[k] === 'denied' ? 'bad' : ''">
          <Check v-if="perms[k] === 'granted'" :size="12" />{{ t('perm_' + (perms[k] || 'prompt')) }}
        </span>
      </div>
      <button class="row" :aria-label="t('allowBackground')" @click="mesh.requestBatteryExemption()">
        <BatteryCharging :size="22" :stroke-width="1.75" />
        <span class="grow"><span class="label">{{ t('allowBackground') }}</span><br /><span class="hint">{{ t('optional') }}</span></span>
        <span v-if="perms.battery" class="chip" :class="perms.battery === 'granted' ? 'ok' : ''">
          <Check v-if="perms.battery === 'granted'" :size="12" />{{ t('perm_' + perms.battery) }}
        </span>
      </button>
    </div>
    <button class="btn" style="width: 100%; max-width: 420px" @click="grant">{{ t('grantPermissions') }}</button>
  </main>
</template>
