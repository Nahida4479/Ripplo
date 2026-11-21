<script setup>
import { ref } from 'vue'
import { KeyRound } from 'lucide-vue-next'
import { createProfile } from '../core/api.js'
import { t } from '../i18n.js'
const name = ref('')
const busy = ref(false)
async function go() { busy.value = true; try { await createProfile(name.value.trim()) } finally { busy.value = false } }
</script>
<template>
  <main class="page center">
    <KeyRound :size="48" :stroke-width="1.5" color="var(--accent)" />
    <h1 style="margin: 0">{{ t('welcome') }}</h1>
    <p>{{ t('onboardHint') }}</p>
    <form style="width: 100%; max-width: 420px; display: grid; gap: 12px" @submit.prevent="go">
      <input v-model="name" class="field" maxlength="32" :placeholder="t('yourName')" :aria-label="t('yourName')" autocomplete="off" />
      <button class="btn" :disabled="!name.trim() || busy">{{ t('generateIdentity') }}</button>
    </form>
  </main>
</template>
