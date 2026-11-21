import { App } from '@capacitor/app'
import { state } from '../core/state.js'
import { refreshPeople } from '../core/api.js'
import { isDue, SLOT_MS } from '../lib/schedule.js'

function tick() {
  if (!state.profile || state.peopleRefreshing) return
  if (isDue(state.profile.tag, state.peopleRefreshedAt || 0)) refreshPeople().catch(() => {})
}

export function startScheduler() {
  setInterval(tick, SLOT_MS)
  App.addListener('resume', tick)
  tick()
}
