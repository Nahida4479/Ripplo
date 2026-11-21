import { reactive } from 'vue'
import { App as CapApp } from '@capacitor/app'
import { mesh } from '../mesh/bridge.js'
import { state } from '../core/state.js'
import { saveSettings } from '../core/api.js'
import { t } from '../i18n.js'

const AWAY = 30000
export const lock = reactive({ locked: false, busy: false })
let hiddenAt = 0

export async function unlock() {
  if (lock.busy) return
  lock.busy = true
  try {
    if ((await mesh.authenticate(t('unlockReason'))).ok) lock.locked = false
  } catch {} finally { lock.busy = false }
}

export async function setAppLock(on) {
  if (!(await mesh.authenticate(t('unlockReason'))).ok) return false
  await saveSettings({ appLock: on })
  await mesh.setSecure(on)
  return true
}

function away() {
  if (!lock.locked && !lock.busy && !hiddenAt) hiddenAt = Date.now()
}

function back() {
  const long = hiddenAt && Date.now() - hiddenAt > AWAY
  hiddenAt = 0
  if (long && state.settings.appLock) {
    lock.locked = true
    unlock()
  }
}

export function startLock() {
  mesh.setSecure(!!state.settings.appLock).catch(() => {})
  if (state.settings.appLock) {
    lock.locked = true
    unlock()
  }
  document.addEventListener('visibilitychange', () => (document.hidden ? away() : back()))
  if (mesh.isNative) CapApp.addListener('appStateChange', ({ isActive }) => (isActive ? back() : away())).catch(() => {})
}
