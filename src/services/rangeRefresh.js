import { mesh } from '../mesh/bridge.js'
import { state } from '../core/state.js'

// Range info (links and seen media of neighbours) is refreshed when a chat opens.
// Shared across all opens: at most MAX refreshes in any WINDOW_MS span.
const WINDOW_MS = 10000
const MAX = 2
const stamps = []

export async function refreshRange() {
  const now = Date.now()
  while (stamps.length && now - stamps[0] > WINDOW_MS) stamps.shift()
  if (stamps.length >= MAX) return
  stamps.push(now)
  try {
    for (const f of (await mesh.getNeighbors()) || []) {
      const cur = state.neighbors.find((n) => n.node === f.node)
      if (cur) { cur.links = f.links; cur.seen = f.seen }
    }
  } catch {}
}
