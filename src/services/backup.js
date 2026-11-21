import { mesh } from '../mesh/bridge.js'
import { state } from '../core/state.js'

export const backupMeta = () => ({ app: __APP_VERSION__, created: Date.now(), ripploId: state.profile?.ripploId })
export const groupCode = (s) => String(s).replace(/\D/g, '').slice(0, 30).match(/.{1,5}/g)?.join(' ') ?? ''

export async function autoBackup() {
  if (!mesh.isNative) return
  try {
    const s = await mesh.backupStatus()
    if (s.enabled && s.folder) await mesh.backupCreate({ mode: 'auto', meta: backupMeta() })
  } catch {}
}

export function startBackup() {
  autoBackup()
  document.addEventListener('visibilitychange', () => { if (!document.hidden) autoBackup() })
}
