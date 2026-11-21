import { createApp } from 'vue'
import { App as Cap } from '@capacitor/app'
import App from './App.vue'
import router from './router.js'
import { initTheme } from './services/theme.js'
import { addContactFromLink } from './core/api.js'
import { ui, toast } from './components/ui.js'
import { t } from './i18n.js'
import './styles/main.css'

initTheme()

Cap.addListener('appUrlOpen', ({ url }) => {
  if (!url?.startsWith('ripplo://add/')) return
  ui.confirm = {
    title: t('addContact'), text: t('deepLinkConfirm'), ok: t('add'),
    onOk: async () => {
      try { const c = await addContactFromLink(url, 'link'); router.push('/contact/' + c.id) }
      catch (e) { toast(t('err_' + (e.code || 'bad_link'))) }
    }
  }
})

createApp(App).use(router).mount('#app')
