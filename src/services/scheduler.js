import { App } from '@capacitor/app'
import { state } from '../core/state.js'
import { refreshPeople } from '../core/api.js'

const STALE = 20 * 3600e3

function tick() {
  const h = new Date().getHours()
  if (!state.profile || h < 2 || h >= 5 || state.peopleRefreshing) return
  if (Date.now() - (state.peopleRefreshedAt || 0) > STALE) refreshPeople().catch(() => {})
}

export function startScheduler() {
  setInterval(tick, 30 * 60e3)
  App.addListener('resume', tick)
  tick()
}
