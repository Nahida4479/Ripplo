<script setup>
import { ref, computed } from 'vue'
import { useRouter } from 'vue-router'
import { QrCode, Pencil, Mic, Waves } from 'lucide-vue-next'
import { state } from '../core/state.js'
import { ui } from '../components/ui.js'
import { t } from '../i18n.js'
import Avatar from '../components/Avatar.vue'

const router = useRouter()
const q = ref('')
const list = computed(() => state.chats.filter(c => c.name.toLowerCase().includes(q.value.toLowerCase())))
const shield = c => c.type === 'direct' && state.contacts[c.id]?.verification === 'none'
const fmt = ts => {
  if (!ts) return ''
  const d = new Date(ts)
  return d.toDateString() === new Date().toDateString()
    ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : d.toLocaleDateString([], { day: 'numeric', month: 'short' })
}
</script>
<template>
  <main class="page">
    <header class="hdr">
      <button class="icon-btn" :aria-label="t('profile')" @click="router.push('/settings')">
        <Avatar :name="state.profile?.name" :photo="state.profile?.avatar" :size="36" />
      </button>
      <h1>{{ t('chats') }}</h1>
      <button class="icon-btn" :aria-label="t('addContact')" @click="ui.add = { mode: 'add' }"><QrCode :size="22" :stroke-width="1.75" /></button>
      <button class="icon-btn" :aria-label="t('newChat')" @click="ui.newChat = 'chat'"><Pencil :size="22" :stroke-width="1.75" /></button>
    </header>
    <input v-model="q" class="field search" type="search" :placeholder="t('search')" :aria-label="t('search')" />
    <div v-if="!state.chats.length" class="center">
      <Waves :size="72" :stroke-width="1" color="var(--accent)" />
      <p>{{ t('emptyChats') }}</p>
      <button class="btn" @click="ui.add = { mode: 'add' }">{{ t('addContact') }}</button>
    </div>
    <button v-for="c in list" :key="c.id" class="list-row" @click="router.push('/chat/' + c.id)">
      <Avatar :name="c.name" :photo="state.contacts[c.id]?.avatar" :group="c.type === 'group'" :shield="shield(c)" />
      <span class="grow">
        <span class="name" style="display: block">{{ c.name }}</span>
        <span class="prev"><template v-if="c.lastKind === 'voice'"><Mic :size="14" />{{ t('voiceMessage') }}</template><template v-else-if="c.lastKind">{{ t(c.lastKind === 'video' ? 'videoMessage' : 'photoMessage') }}</template><template v-else>{{ c.lastText }}</template></span>
      </span>
      <span class="meta">{{ fmt(c.lastTs) }}<span v-if="c.unread" class="badge" :aria-label="t('unread')">{{ c.unread }}</span></span>
    </button>
  </main>
</template>
