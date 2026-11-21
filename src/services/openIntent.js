import { watch } from 'vue'
import { App } from '@capacitor/app'
import { mesh } from '../mesh/bridge.js'
import { state } from '../core/state.js'
import { acceptCall } from '../core/api.js'
import { onNotificationTap } from './notifications.js'

const ANSWER_WINDOW = 20000
const CHAT_ID = /^[0-9A-HJKMNP-TV-Z]{16}$|^[A-Za-z0-9_-]{6,32}$/
const go = (router, id) => { if (CHAT_ID.test(String(id))) router.push('/chat/' + id) }

export function startOpen(router) {
  let want = null

  async function take() {
    const o = await mesh.takeOpen()
    if (!o) return
    go(router, o.chatId)
    if (o.answer) want = { peer: o.chatId, id: o.answer, until: Date.now() + ANSWER_WINDOW }
  }

  watch(
    () => [state.call?.status, state.call?.peer, state.call?.dir, state.call?.id],
    ([status, peer, dir, id]) => {
      if (want && status === 'ringing' && dir === 'in' && peer === want.peer && id === want.id && Date.now() < want.until) {
        want = null
        acceptCall()
      }
    },
    { immediate: true },
  )
  onNotificationTap((chatId) => go(router, chatId))
  take()
  mesh.on('open', take)
  App.addListener('resume', take)
}
