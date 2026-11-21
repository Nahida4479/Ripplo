import { reactive } from 'vue'

export function createState() {
  return reactive({
    ready: false,
    needsOnboarding: false,
    insecureStorage: false,
    profile: null,
    contacts: {},
    chats: [],
    messages: {},
    neighbors: [],
    people: [],
    peopleRefreshedAt: 0,
    peopleRefreshing: false,
    update: { checking: false, latest: null, available: false, url: null, apkUrl: null, sha256: null, progress: 0, error: null },
    integrity: { status: 'unknown', checkedAt: 0 },
    settings: { autoUpdate: true, backgroundRelay: true },
  })
}

export const state = createState()
