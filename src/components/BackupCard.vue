<script setup>
import { ref, computed, onMounted } from 'vue'
import { mesh } from '../mesh/bridge.js'
import { ui, toast } from './ui.js'
import { t, locale } from '../i18n.js'
import { backupMeta } from '../services/backup.js'

const status = ref({ enabled: false, lastAt: 0, folder: null })
const step = ref(null)
const code = ref('')
const setup = ref(false)
const check = ref('')
const busy = ref(false)
const groups = computed(() => code.value.match(/.{1,5}/g) || [])
const last = computed(() => (status.value.lastAt ? new Date(status.value.lastAt).toLocaleString(locale.value) : null))

const refresh = async () => { status.value = await mesh.backupStatus().catch(() => status.value) }
onMounted(() => mesh.isNative && refresh())

async function run(fn) {
  busy.value = true
  try { await fn() } catch (e) {
    if (e?.code !== 'cancelled') toast(t(e?.code === 'auth_failed' ? 'bk_auth_failed' : 'bk_failed'))
  } finally { busy.value = false }
}

const close = () => { step.value = null; code.value = ''; check.value = '' }
const enable = () => run(async () => { code.value = (await mesh.backupEnable()).code; setup.value = true; step.value = 'code'; await refresh() })
const show = () => run(async () => { code.value = (await mesh.backupShowCode()).code; setup.value = false; step.value = 'code' })
const wrote = () => { check.value = ''; step.value = 'check' }
const verify = () => {
  if (check.value.replace(/\D/g, '') !== groups.value[groups.value.length - 1]) return toast(t('codeMismatch'))
  code.value = ''
  step.value = 'folder'
}
const folder = () => run(async () => { await mesh.backupChooseFolder(); close(); await refresh() })
const now = () => run(async () => { await mesh.backupCreate({ mode: 'pick', meta: backupMeta() }); toast(t('backupDone')); await refresh() })
const off = () => { ui.confirm = { title: t('backupOff'), text: t('backupOffConfirm'), ok: t('backupOff'), danger: true, onOk: () => run(async () => { await mesh.backupDisable(); await refresh() }) } }
</script>
<template>
  <h2 class="section">{{ t('backup') }}</h2>
  <div class="card pad">
    <p v-if="!mesh.isNative" class="hint">{{ t('backupWeb') }}</p>
    <template v-else-if="step === 'code'">
      <b>{{ t('codeTitle') }}</b>
      <div class="code mono" :aria-label="t('codeTitle')"><span v-for="(g, i) in groups" :key="i">{{ g }}</span></div>
      <p class="hint">{{ t('codeWarn') }}</p>
      <button v-if="setup" class="btn block" @click="wrote">{{ t('codeWritten') }}</button>
      <button v-else class="btn block" @click="close">{{ t('done') }}</button>
    </template>
    <form v-else-if="step === 'check'" class="stack" @submit.prevent="verify">
      <b>{{ t('codeCheckTitle') }}</b>
      <p class="hint">{{ t('codeCheckHint') }}</p>
      <input v-model="check" class="field mono" inputmode="numeric" maxlength="5" autocomplete="off" :aria-label="t('codeCheckTitle')" />
      <div class="acts"><button type="button" class="btn ghost" @click="step = 'code'">{{ t('back') }}</button><button class="btn" :disabled="check.length < 5">{{ t('continue') }}</button></div>
    </form>
    <div v-else-if="step === 'folder'" class="stack">
      <b>{{ t('folderTitle') }}</b>
      <p class="hint">{{ t('folderHint') }}</p>
      <div class="acts"><button class="btn ghost" @click="close">{{ t('notNow') }}</button><button class="btn" :disabled="busy" @click="folder">{{ t('chooseFolder') }}</button></div>
    </div>
    <div v-else-if="!status.enabled" class="stack">
      <p class="hint">{{ t('backupIntro') }}</p>
      <button class="btn block" :disabled="busy" @click="enable">{{ t('backupEnable') }}</button>
    </div>
    <div v-else class="stack">
      <div>{{ last ? t('backupLast', { time: last }) : t('backupNever') }}<br />
        <span class="hint">{{ status.folder ? t('backupFolder', { name: status.folder }) : t('backupNoFolder') }}</span></div>
      <p class="hint">{{ t('codeWarn') }}</p>
      <div class="acts"><button class="btn" :disabled="busy" @click="now">{{ t('backupNow') }}</button><button class="btn ghost" :disabled="busy" @click="folder">{{ t('chooseFolder') }}</button></div>
      <div class="acts"><button class="btn ghost" :disabled="busy" @click="show">{{ t('showCode') }}</button><button class="btn danger" :disabled="busy" @click="off">{{ t('backupOff') }}</button></div>
    </div>
  </div>
</template>
<style scoped>
.pad { padding: 14px; }
.stack { display: grid; gap: 12px; }
.hint { font-size: 13px; color: var(--text-2); margin: 8px 0; }
.stack .hint { margin: 0; }
.code { display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; margin: 12px 0; font-size: 22px; font-weight: 600; letter-spacing: .08em; text-align: center; }
.code span { background: var(--surface-2); border-radius: 12px; padding: 10px 0; }
.acts { display: flex; gap: 8px; flex-wrap: wrap; }
.acts .btn { flex: 1; }
</style>
