import { mesh } from '../mesh/bridge.js'
import { state } from './state.js'
import { createCore, MAX_TEXT, MAX_FILE } from './messenger.js'

const core = createCore({ mesh, state })

export { state, MAX_TEXT, MAX_FILE }
export const {
  init, createProfile, myInviteLink, addContactFromLink, addPerson, verifyNearby, verifyByQr, markVerified,
  safetyNumber, sendText, sendAttachment, retry, loadMessages, markRead, createGroup, refreshPeople,
  deleteChat, deleteContact, saveSettings,
} = core
