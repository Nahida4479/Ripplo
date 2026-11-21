import { createRouter, createWebHashHistory } from 'vue-router'

export default createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', component: () => import('./views/ChatsView.vue') },
    { path: '/people', component: () => import('./views/PeopleView.vue') },
    { path: '/settings', component: () => import('./views/SettingsView.vue') },
    { path: '/chat/:id', component: () => import('./views/ChatView.vue'), meta: { full: true } },
    { path: '/contact/:id', component: () => import('./views/ContactView.vue'), meta: { full: true } }
  ]
})
