<script setup>
import { ui } from './ui.js'
import { t } from '../i18n.js'
const close = () => { ui.confirm = null }
const ok = async () => { const c = ui.confirm; close(); await c.onOk() }
</script>
<template>
  <div v-if="ui.confirm" class="scrim" @click.self="close">
    <div class="sheet" role="dialog" aria-modal="true" :aria-label="ui.confirm.title">
      <h3>{{ ui.confirm.title }}</h3>
      <p>{{ ui.confirm.text }}</p>
      <div class="actions">
        <button class="btn ghost" @click="close">{{ t('cancel') }}</button>
        <button class="btn" :class="{ danger: ui.confirm.danger }" @click="ok">{{ ui.confirm.ok }}</button>
      </div>
    </div>
  </div>
</template>
