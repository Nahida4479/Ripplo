import { App } from '@capacitor/app'
import { mesh } from '../mesh/bridge.js'
import { ui } from '../components/ui.js'

async function check() {
  const s = await mesh.takeShare()
  if (s) ui.share = s
}

export function startShare() {
  check()
  mesh.on('share', check)
  App.addListener('resume', check)
}
