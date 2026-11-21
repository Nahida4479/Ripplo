import { Capacitor } from '@capacitor/core'

let openChat = null
let tapCb = null
let nativeReady = null
let nextId = 1

export const setOpenChat = (id) => { openChat = id }
export const onNotificationTap = (cb) => { tapCb = cb }

const visible = () => typeof document !== 'undefined' && !document.hidden

async function native() {
  nativeReady ??= (async () => {
    const { LocalNotifications } = await import('@capacitor/local-notifications')
    const perm = await LocalNotifications.checkPermissions()
    if (perm.display !== 'granted' && (await LocalNotifications.requestPermissions()).display !== 'granted') return null
    await LocalNotifications.addListener('localNotificationActionPerformed', (e) => {
      const id = e.notification?.extra?.chatId
      if (id && tapCb) tapCb(id)
    })
    return LocalNotifications
  })()
  return nativeReady
}

export async function notify({ title, body, chatId }) {
  if (visible() && openChat === chatId) return
  try {
    if (Capacitor.isNativePlatform()) {
      const ln = await native()
      if (ln) await ln.schedule({ notifications: [{ id: nextId++ % 2147483647, title, body, extra: { chatId } }] })
    } else if (typeof Notification !== 'undefined') {
      if (Notification.permission === 'default') await Notification.requestPermission()
      if (Notification.permission === 'granted') {
        const n = new Notification(title, { body })
        n.onclick = () => { if (tapCb) tapCb(chatId) }
      }
    }
  } catch {
    return
  }
}
