<script setup>
import { ref } from 'vue'
import { KeyRound } from 'lucide-vue-next'
import { createProfile, restoreBackup } from '../core/api.js'
import { mesh } from '../mesh/bridge.js'
import { groupCode } from '../services/backup.js'
import { t } from '../i18n.js'
const name = ref('')
const busy = ref(false)
const restoring = ref(false)
const code = ref('')
const error = ref('')
async function restore() {
  busy.value = true
  error.value = ''
  try { await restoreBackup(code.value.replace(/\D/g, '')); location.reload() } catch (e) {
    error.value = t(['bad_code', 'bad_file', 'need_factor'].includes(e?.code) ? 'bk_' + e.code : 'bk_failed')
  } finally { busy.value = false }
}
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
    <template v-if="mesh.isNative">
      <form v-if="restoring" style="width: 100%; max-width: 420px; display: grid; gap: 12px" @submit.prevent="restore">
        <p style="max-width: none">{{ t('restoreHint') }}</p>
        <input :value="code" class="field mono" inputmode="numeric" autocomplete="off" :placeholder="t('recoveryCode')" :aria-label="t('recoveryCode')" @input="code = groupCode($event.target.value)" />
        <p v-if="error" role="alert" style="color: var(--danger); max-width: none">{{ error }}</p>
        <button class="btn" :disabled="code.replace(/\D/g, '').length !== 30 || busy">{{ t('restore') }}</button>
      </form>
      <button v-else class="btn ghost" style="width: 100%; max-width: 420px" @click="restoring = true">{{ t('restoreFromBackup') }}</button>
    </template>
  </main>
</template>
