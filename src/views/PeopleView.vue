<script setup>
import { computed } from 'vue'
import { RefreshCw, Check } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { refreshPeople, addPerson } from '../core/api.js'
import { ui, toast } from '../components/ui.js'
import { t, locale } from '../i18n.js'
import Avatar from '../components/Avatar.vue'

const MEDIUM = { ble: 'BLE', lan: 'LAN', wifi_direct: 'Wi-Fi Direct', wifidirect: 'Wi-Fi Direct', aware: 'Wi-Fi Aware', multipeer: 'Multipeer', l2cap: 'BLE' }
const medium = m => MEDIUM[String(m).toLowerCase()] || m
const nearby = computed(() => state.neighbors.filter(n => n.card))
const isContact = id => !!state.contacts[id]
const last = computed(() => state.peopleRefreshedAt
  ? new Date(state.peopleRefreshedAt).toLocaleTimeString(locale.value, { hour: '2-digit', minute: '2-digit' }) : '–')

function add(p) {
  ui.confirm = {
    title: t('addPersonTitle', { name: p.name }), text: t('unverifiedWarning'), ok: t('add'),
    onOk: async () => { try { await addPerson(p); toast(t('added')) } catch (e) { toast(e.message) } }
  }
}
const nearbyPerson = n => ({ id: n.card.id, name: n.card.name, card: n.card.card, hops: 0 })
</script>
<template>
  <main class="page">
    <header class="hdr">
      <div style="flex: 1">
        <h1>{{ t('people') }}</h1>
        <div class="sub">{{ t('lastRefreshed', { time: last }) }} · {{ t('nextTonight') }}</div>
      </div>
      <button class="icon-btn" :class="{ spin: state.peopleRefreshing }" :aria-label="t('refresh')" :disabled="state.peopleRefreshing" @click="refreshPeople()">
        <RefreshCw :size="22" :stroke-width="1.75" />
      </button>
    </header>

    <h2 class="section">{{ t('nearby') }}</h2>
    <div class="card">
      <div v-if="!nearby.length" class="empty">{{ t('nobodyNearby') }}</div>
      <div v-for="n in nearby" :key="n.node" class="row">
        <Avatar :name="n.card.name" :size="40" />
        <span class="grow"><span class="label">{{ n.card.name }}</span><br />
          <span class="chip">{{ medium(n.medium) }}</span> <span class="hint">{{ n.kbps }} kbps</span></span>
        <Check v-if="isContact(n.card.id)" :size="22" color="var(--ok)" :aria-label="t('inContacts')" />
        <button v-else class="btn sm" @click="add(nearbyPerson(n))">{{ t('add') }}</button>
      </div>
    </div>

    <h2 class="section">{{ t('inMesh') }}</h2>
    <div class="card">
      <div v-if="!state.people.length" class="empty">{{ t('nobodyInMesh') }}</div>
      <div v-for="p in state.people" :key="p.id" class="row">
        <Avatar :name="p.name" :size="40" />
        <span class="grow"><span class="label">{{ p.name }}</span><br /><span class="hint">{{ t('hops', { n: p.hops }) }}</span></span>
        <Check v-if="p.isContact || isContact(p.id)" :size="22" color="var(--ok)" :aria-label="t('inContacts')" />
        <button v-else class="btn sm" @click="add(p)">{{ t('add') }}</button>
      </div>
    </div>
  </main>
</template>
