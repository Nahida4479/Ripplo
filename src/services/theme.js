import { reactive, watch } from 'vue'

export const ACCENTS = ['#22c55e', '#14b8a6', '#4f9cf9', '#a78bfa', '#e467b0', '#ea6a5f', '#e67e22', '#9ca3af']
export const GRADIENTS = ['', '#5b2ea6', '#1e3a8a', '#0f5257', '#7a1f4f', '#6b3a0a', '#3d4552']

const KEY = 'ripplo.theme'
const load = () => { try { return JSON.parse(localStorage.getItem(KEY)) || {} } catch { return {} } }

export const theme = reactive({ mode: 'system', accent: '#4f9cf9', gradient: '', ...load() })

function luminance(hex) {
  const c = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(v => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

export function applyTheme() {
  const mq = window.matchMedia?.('(prefers-color-scheme: light)')
  const light = theme.mode === 'light' || (theme.mode === 'system' && mq?.matches)
  const root = document.documentElement
  root.dataset.theme = light ? 'light' : 'dark'
  root.style.setProperty('--accent', theme.accent)
  const L = luminance(theme.accent)
  root.style.setProperty('--on-accent', 1.05 / (L + 0.05) >= (L + 0.05) / 0.0556 ? '#fff' : '#111')
  root.style.setProperty('--glow', theme.gradient || 'transparent')
  const bg = getComputedStyle(root).getPropertyValue('--bg').trim()
  document.querySelector('meta[name=theme-color]')?.setAttribute('content', bg)
}

export function initTheme() {
  watch(theme, () => {
    try { localStorage.setItem(KEY, JSON.stringify(theme)) } catch {}
    applyTheme()
  }, { deep: true })
  window.matchMedia?.('(prefers-color-scheme: light)').addEventListener?.('change', applyTheme)
  applyTheme()
}
