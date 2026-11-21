import { mesh } from '../mesh/bridge.js'

export const REQUIRED = ['bluetooth', 'wifi', 'notifications']
export const allGranted = p => REQUIRED.every(k => p[k] === 'granted')

export async function checkPermissions() {
  if (!mesh.isNative) return { bluetooth: 'granted', wifi: 'granted', notifications: 'granted' }
  return mesh.checkPermissions()
}

export async function requestPermissions() {
  if (!mesh.isNative) return checkPermissions()
  return mesh.requestPermissions()
}
