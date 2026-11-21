import { watch } from 'vue'
import { App } from '@capacitor/app'
import { mesh } from '../mesh/bridge.js'
import { state } from '../core/state.js'
import { acceptCall } from '../core/api.js'
import { onNotificationTap } from './notifications.js'

const ANSWER_WINDOW = 20000

export function startOpen(router) {
  let want = null

  async function take() {
    const o = await mesh.takeOpen()
    if (!o) return
    router.push('/chat/' + o.chatId)
    if (o.answer) want = { peer: o.chatId, until: Date.now() + ANSWER_WINDOW }
  }

  watch(
    () => [state.call?.status, state.call?.peer, state.call?.dir],
    ([status, peer, dir]) => {
      if (want && status === 'ringing' && dir === 'in' && peer === want.peer && Date.now() < want.until) {
        want = null
        acceptCall()
      }
    },
    { immediate: true },
  )
  onNotificationTap((chatId) => router.push('/chat/' + chatId))
  take()
  mesh.on('open', take)
  App.addListener('resume', take)
}
