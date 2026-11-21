import { mesh } from '../mesh/bridge.js'
import { state } from './state.js'
import { createCore, MAX_TEXT, MAX_FILE } from './messenger.js'

const devProfile = !mesh.isNative && new URLSearchParams(location.search).get('profile')
const core = createCore({ mesh, state, dbName: devProfile ? `ripplo-${devProfile}` : 'ripplo' })

export { state, MAX_TEXT, MAX_FILE }
export const {
  init, createProfile, setAvatar, setName, myInviteLink, addContactFromLink, addPerson, verifyNearby, verifyByQr, markVerified,
  safetyNumber, sendText, sendAttachment, retry, loadMessages, markRead, createGroup, refreshPeople,
  deleteChat, deleteContact, saveSettings, restoreBackup,
} = core
