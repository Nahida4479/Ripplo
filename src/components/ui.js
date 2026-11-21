import { reactive } from 'vue'

export const ui = reactive({ add: null, newChat: null, confirm: null, toastText: '' })

let timer
export function toast(text) {
  ui.toastText = text
  clearTimeout(timer)
  timer = setTimeout(() => { ui.toastText = '' }, 3000)
}
