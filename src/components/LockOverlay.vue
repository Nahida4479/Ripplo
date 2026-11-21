<script setup>
import { Lock } from 'lucide-vue-next'
import { lock, unlock } from '../services/lock.js'
import { t } from '../i18n.js'
</script>
<template>
  <div class="lockscreen" role="dialog" aria-modal="true" :aria-label="t('locked')">
    <img src="/icon.svg" width="88" height="88" alt="Ripplo" />
    <h1 style="margin: 0">Ripplo</h1>
    <p>{{ t('locked') }}</p>
    <button class="btn" style="min-width: 200px" :disabled="lock.busy" @click="unlock"><Lock :size="18" :stroke-width="1.75" />{{ t('unlock') }}</button>
  </div>
</template>
<style scoped>
.lockscreen { position: fixed; inset: 0; z-index: 100; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 16px; padding: 24px; text-align: center; background: linear-gradient(180deg, color-mix(in srgb, var(--glow) 55%, transparent) 0, transparent 340px), var(--bg); }
.lockscreen p { color: var(--text-2); margin: 0; }
</style>
