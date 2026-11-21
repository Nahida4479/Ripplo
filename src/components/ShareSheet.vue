<script setup>
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { Capacitor } from '@capacitor/core'
import { state } from '../core/state.js'
import { sendText, sendAttachment, MAX_TEXT } from '../core/api.js'
import { ui, toast } from './ui.js'
import { t } from '../i18n.js'
import Avatar from './Avatar.vue'

const router = useRouter()
const chats = computed(() => state.chats.filter(c => c.type === 'group' || !state.contacts[c.id]?.request))
const preview = computed(() => ui.share.kind === 'text' ? ui.share.text.slice(0, 120)
  : t(ui.share.kind === 'video' ? 'videoMessage' : ui.share.kind === 'voice' ? 'voiceMessage' : 'photoMessage'))
const close = () => { ui.share = null }

async function pick(c) {
  const s = ui.share
  try {
    if (s.kind === 'text') {
      if (s.text.length > MAX_TEXT) return toast(t('shareTooLong'))
      await sendText(c.id, s.text)
    } else {
      const res = await fetch(Capacitor.convertFileSrc('file://' + s.path))
      await sendAttachment(c.id, new Blob([await res.blob()], { type: s.mime }), s.kind)
    }
    close()
    router.push('/chat/' + c.id)
  } catch (e) {
    toast(e.code === 'media_locked' ? t('err_media_locked') : e.message || t('playFailed'))
  }
}
</script>
<template>
  <div v-if="ui.share" class="scrim" @click.self="close">
    <div class="sheet" role="dialog" aria-modal="true" :aria-label="t('shareTo')">
      <h3>{{ t('shareTo') }}</h3>
      <img v-if="ui.share.kind === 'image'" :src="Capacitor.convertFileSrc('file://' + ui.share.path)" alt="" class="thumb" />
      <p class="hint" style="margin: 0 0 12px; overflow-wrap: anywhere">{{ preview }}</p>
      <div class="card" style="max-height: 50vh; overflow-y: auto">
        <div v-if="!chats.length" class="empty">{{ t('noContacts') }}</div>
        <button v-for="c in chats" :key="c.id" class="list-row" @click="pick(c)">
          <Avatar :name="c.name" :photo="state.contacts[c.id]?.avatar" :group="c.type === 'group'" :size="40" />
          <span class="grow"><span class="name">{{ c.name }}</span></span>
        </button>
      </div>
      <button class="btn ghost block" style="margin-top: 12px" @click="close">{{ t('cancel') }}</button>
    </div>
  </div>
</template>
<style scoped>
.hint { color: var(--text-2); font-size: 13px; }
.thumb { display: block; max-width: 100%; max-height: 120px; border-radius: 12px; margin: 0 0 8px; }
</style>
