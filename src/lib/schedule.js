export const SLOT_MS = 15000
export const WINDOW_MS = 3 * 3600e3
export const STALE_MS = 20 * 3600e3
const SLOTS = WINDOW_MS / SLOT_MS

export const slotOf = (tag) => parseInt(String(tag).slice(0, 8), 16) % SLOTS

export function windowStart(now) {
  const d = new Date(now)
  d.setHours(2, 0, 0, 0)
  return d.getTime()
}

export function isDue(tag, last, now = Date.now()) {
  const start = windowStart(now)
  return now >= start + slotOf(tag) * SLOT_MS && now < start + WINDOW_MS && now - last > STALE_MS
}
