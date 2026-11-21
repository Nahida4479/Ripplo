<script setup>
import { ref, computed } from 'vue'
import { useRoute } from 'vue-router'
import { MessageCircle, Users, Settings } from 'lucide-vue-next'
import { state } from './core/state.js'
import { init } from './core/api.js'
import { t } from './i18n.js'
import { ui } from './components/ui.js'
import { startUpdater } from './services/updater.js'
import { startScheduler } from './services/scheduler.js'
import GateView from './views/GateView.vue'
import OnboardingView from './views/OnboardingView.vue'
import AddContactSheet from './components/AddContactSheet.vue'
import NewChatSheet from './components/NewChatSheet.vue'
import ConfirmSheet from './components/ConfirmSheet.vue'

const route = useRoute()
const granted = ref(false)
const alert = computed(() => state.update.available || state.integrity.status === 'mismatch')
const tabs = [['/', MessageCircle, 'chats'], ['/people', Users, 'people'], ['/settings', Settings, 'settings']]

async function onGranted() {
  granted.value = true
  await init()
  startUpdater()
  startScheduler()
}
</script>
<template>
  <GateView v-if="!granted" @granted="onGranted" />
  <div v-else-if="!state.ready" class="center" role="status">Ripplo…</div>
  <OnboardingView v-else-if="state.needsOnboarding" />
  <template v-else>
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
  </template>
  <ConfirmSheet />
  <div v-if="ui.toastText" class="toast" role="status">{{ ui.toastText }}</div>
</template>
