<script setup>
import { ref, computed } from 'vue'
import { useRouter } from 'vue-router'
import { state } from '../core/state.js'
import { createGroup } from '../core/api.js'
import { ui, toast } from './ui.js'
import { t } from '../i18n.js'
import Avatar from './Avatar.vue'
import { Check } from 'lucide-vue-next'

const router = useRouter()
const group = computed(() => ui.newChat === 'group')
const name = ref('')
const picked = ref([])
const contacts = computed(() => Object.values(state.contacts).filter(c => !c.request).sort((a, b) => a.name.localeCompare(b.name)))
const close = () => { ui.newChat = null; name.value = ''; picked.value = [] }

async function pick(c) {
  if (!group.value) { close(); router.push('/chat/' + c.id); return }
  picked.value = picked.value.includes(c.id) ? picked.value.filter(x => x !== c.id) : [...picked.value, c.id]
}
async function create() {
  try {
    const chat = await createGroup(name.value.trim(), picked.value)
    close(); router.push('/chat/' + chat.id)
  } catch (e) { toast(e.message) }
}
</script>
<template>
  <div v-if="ui.newChat" class="scrim" @click.self="close">
    <div class="sheet" role="dialog" aria-modal="true">
      <h3>{{ group ? t('newGroup') : t('newChat') }}</h3>
      <div class="seg" style="margin-bottom: 12px">
        <button :aria-pressed="!group" @click="ui.newChat = 'chat'">{{ t('newChat') }}</button>
        <button :aria-pressed="group" @click="ui.newChat = 'group'">{{ t('newGroup') }}</button>
      </div>
      <input v-if="group" v-model="name" class="field" maxlength="40" :placeholder="t('groupName')" :aria-label="t('groupName')" style="margin-bottom: 8px" />
      <div v-if="!contacts.length" class="empty">{{ t('noContacts') }}</div>
      <button v-for="c in contacts" :key="c.id" class="list-row" @click="pick(c)">
        <Avatar :name="c.name" :photo="c.avatar" :size="40" :shield="c.verification === 'none'" />
        <span class="grow name">{{ c.name }}</span>
        <Check v-if="picked.includes(c.id)" :size="22" color="var(--accent)" />
      </button>
      <div class="actions" style="margin-top: 12px">
        <button class="btn ghost" @click="close">{{ t('cancel') }}</button>
        <button v-if="group" class="btn" :disabled="!name.trim() || !picked.length" @click="create">{{ t('create') }}</button>
      </div>
    </div>
  </div>
</template>
