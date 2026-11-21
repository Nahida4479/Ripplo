<script setup>
import { ref, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { MessageCircle, Users, Settings } from 'lucide-vue-next'
import { state } from './core/state.js'
import { init } from './core/api.js'
import { t } from './i18n.js'
import { ui } from './components/ui.js'
import { startUpdater } from './services/updater.js'
import { startScheduler } from './services/scheduler.js'
import { startLock, lock } from './services/lock.js'
import { startBackup } from './services/backup.js'
import { startShare } from './services/share.js'
import { startOpen } from './services/openIntent.js'
import LockOverlay from './components/LockOverlay.vue'
import GateView from './views/GateView.vue'
import OnboardingView from './views/OnboardingView.vue'
import AddContactSheet from './components/AddContactSheet.vue'
import NewChatSheet from './components/NewChatSheet.vue'
import ConfirmSheet from './components/ConfirmSheet.vue'
import ShareSheet from './components/ShareSheet.vue'
import CallOverlay from './components/CallOverlay.vue'

const route = useRoute()
const router = useRouter()
const granted = ref(false)
const alert = computed(() => state.update.available || state.integrity.status === 'mismatch')
const tabs = [['/', MessageCircle, 'chats'], ['/people', Users, 'people'], ['/settings', Settings, 'settings']]

async function onGranted() {
  granted.value = true
  await init()
  startUpdater()
  startScheduler()
  startLock()
  startBackup()
  startShare()
  startOpen(router)
}
</script>
<template>
  <GateView v-if="!granted" @granted="onGranted" />
  <div v-else-if="!state.ready" class="center" role="status">Ripplo…</div>
  <OnboardingView v-else-if="state.needsOnboarding" />
  <template v-else-if="!state.lockedCall">
    <router-view v-slot="{ Component }"><component :is="Component" :key="route.fullPath" /></router-view>
    <nav v-if="!route.meta.full" class="tabbar" :aria-label="t('navigation')">
      <router-link v-for="[to, icon, label] in tabs" :key="to" :to="to" :class="{ on: route.path === to }" :aria-label="t(label)">
        <component :is="icon" :size="22" :stroke-width="1.75" />
        <span v-if="route.path === to">{{ t(label) }}</span>
        <i v-if="to === '/settings' && alert" class="dot" role="img" :aria-label="t('attention')" />
      </router-link>
    </nav>
    <AddContactSheet />
    <NewChatSheet />
    <ShareSheet v-if="!lock.locked" />
  </template>
  <div v-else class="center" role="status">Ripplo…</div>
  <ConfirmSheet v-if="!state.lockedCall" />
  <CallOverlay v-if="state.ready" />
  <LockOverlay v-if="lock.locked && !state.lockedCall" />
  <div v-if="ui.toastText && !state.lockedCall" class="toast" role="status">{{ ui.toastText }}</div>
</template>
