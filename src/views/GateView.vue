<script setup>
import { ref, onMounted } from 'vue'
import { Bluetooth, Wifi, Bell, BatteryCharging, Check } from 'lucide-vue-next'
import { checkPermissions, requestPermissions, allGranted } from '../services/permissions.js'
import { mesh } from '../mesh/bridge.js'
import { t } from '../i18n.js'

const emit = defineEmits(['granted'])
const perms = ref({})
const rows = [['bluetooth', Bluetooth, 'permBluetooth'], ['wifi', Wifi, 'permWifi'], ['notifications', Bell, 'permNotifications']]

async function apply(p) { perms.value = p; if (allGranted(p)) emit('granted') }
onMounted(async () => apply(await checkPermissions()))
const grant = async () => apply(await requestPermissions())
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
      </button>
    </div>
    <button class="btn" style="width: 100%; max-width: 420px" @click="grant">{{ t('grantPermissions') }}</button>
  </main>
</template>
