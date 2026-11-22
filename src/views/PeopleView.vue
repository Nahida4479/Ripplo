<script setup>
import { computed, ref } from 'vue'
import { RefreshCw, Check, Search, X } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { refreshPeople, searchPeople, invite, acceptRequest } from '../core/api.js'
import { ui, toast } from '../components/ui.js'
import { t, locale } from '../i18n.js'
import Avatar from '../components/Avatar.vue'

const MEDIUM = { ble: 'BLE', lan: 'LAN', wifi_direct: 'Wi-Fi Direct', wifidirect: 'Wi-Fi Direct', aware: 'Wi-Fi Aware', multipeer: 'Multipeer', l2cap: 'BLE' }
const medium = m => MEDIUM[String(m).toLowerCase()] || m
const chips = n => {
  const names = [...new Set((n.links?.length ? n.links : [n]).map(l => medium(l.medium)))]
  return names.map((name, i) => ({ name, active: i === 0 }))
}
const nearby = computed(() => state.neighbors.filter(n => n.card))
const isContact = id => !!state.contacts[id] && !state.contacts[id].request
const request = id => state.contacts[id]?.request
const last = computed(() => state.peopleRefreshedAt
  ? new Date(state.peopleRefreshedAt).toLocaleTimeString(locale.value, { hour: '2-digit', minute: '2-digit' }) : '–')

function add(p) {
  ui.confirm = {
    title: t('inviteTitle', { name: p.name }), text: t('inviteText'), ok: t('invite'),
    onOk: async () => { try { await invite(p); toast(t('inviteSent')) } catch (e) { toast(t('err_' + (e.code || 'bad_link'))) } }
  }
}
const q = ref('')
const find = () => searchPeople(q.value)
const clear = () => { q.value = ''; searchPeople('') }
const accept = async id => { try { await acceptRequest(id) } catch (e) { toast(e.message) } }
const nearbyPerson = n => ({ id: n.card.id, name: n.card.name, card: n.card.card, hops: 0 })
</script>
<template>
  <main class="page">
    <header class="hdr">
      <div style="flex: 1">
        <h1>{{ t('people') }}</h1>
        <div class="sub">{{ t('lastRefreshed', { time: last }) }} {{ t('nextTonight') }}</div>
      </div>
      <button class="icon-btn" :class="{ spin: state.peopleRefreshing }" :aria-label="t('refresh')" :disabled="state.peopleRefreshing" @click="refreshPeople()">
        <RefreshCw :size="22" :stroke-width="1.75" />
      </button>
    </header>

    <form class="finder" role="search" @submit.prevent="find">
      <input v-model="q" class="field" type="search" maxlength="40" :placeholder="t('findPlaceholder')" :aria-label="t('findPlaceholder')" :disabled="state.peopleRefreshing" />
      <button v-if="state.peopleQuery" type="button" class="icon-btn" :aria-label="t('close')" @click="clear"><X :size="20" /></button>
      <button class="icon-btn" :aria-label="t('find')" :disabled="state.peopleRefreshing || !q.trim()"><Search :size="22" :stroke-width="1.75" /></button>
    </form>
    <p class="hint finder-hint">{{ t('findHint') }}</p>

    <h2 class="section">{{ t('nearby') }}</h2>
    <div class="card">
      <div v-if="!nearby.length" class="empty">{{ t('nobodyNearby') }}</div>
      <div v-for="n in nearby" :key="n.node" class="row">
        <Avatar :name="n.card.name" :photo="state.contacts[n.card.id]?.avatar" :size="40" />
        <span class="grow"><span class="label">{{ n.card.name }}</span><br />
          <span v-for="c in chips(n)" :key="c.name" class="chip" style="margin-right: 4px">{{ c.name }}<Check v-if="c.active" :size="12" color="var(--ok)" /></span> <span class="hint">{{ n.kbps }} kbps</span></span>
        <Check v-if="isContact(n.card.id)" :size="22" color="var(--ok)" :aria-label="t('inContacts')" />
        <button v-else-if="request(n.card.id) === 'in'" class="btn sm" @click="accept(n.card.id)">{{ t('accept') }}</button>
        <span v-else-if="request(n.card.id) === 'out' && !state.contacts[n.card.id].inviteFailed" class="chip">{{ t('invited') }}</span>
        <button v-else class="btn sm" @click="add(nearbyPerson(n))">{{ request(n.card.id) ? t('retry') : t('invite') }}</button>
      </div>
    </div>

    <h2 class="section">{{ state.peopleQuery ? t('searchResults') : t('inMesh') }}</h2>
    <div class="card">
      <div v-if="!state.people.length" class="empty">{{ state.peopleQuery && !state.peopleRefreshing ? t('noResults') : t('nobodyInMesh') }}</div>
      <div v-for="p in state.people" :key="p.id" class="row">
        <Avatar :name="p.name" :photo="state.contacts[p.id]?.avatar" :size="40" />
        <span class="grow"><span class="label">{{ p.name }}</span><br /><span class="hint">{{ t('hops', { n: p.hops }) }}</span></span>
        <Check v-if="p.isContact || isContact(p.id)" :size="22" color="var(--ok)" :aria-label="t('inContacts')" />
        <button v-else-if="request(p.id) === 'in'" class="btn sm" @click="accept(p.id)">{{ t('accept') }}</button>
        <span v-else-if="request(p.id) === 'out' && !state.contacts[p.id].inviteFailed" class="chip">{{ t('invited') }}</span>
        <button v-else class="btn sm" @click="add(p)">{{ request(p.id) ? t('retry') : t('invite') }}</button>
      </div>
    </div>
  </main>
</template>
<style scoped>
.finder { display: flex; gap: 4px; align-items: center; margin-bottom: 4px; }
.finder .field { flex: 1; }
.finder-hint { color: var(--text-2); font-size: 12px; margin: 0 4px 8px; }
</style>
