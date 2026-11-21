<script setup>
import { computed } from 'vue'
import { Users, ShieldAlert } from 'lucide-vue-next'
const p = defineProps({ name: String, size: { type: Number, default: 48 }, group: Boolean, shield: Boolean, photo: String })
const hue = computed(() => [...(p.name || '?')].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7))
const initials = computed(() => (p.name || '?').trim().split(/\s+/).slice(0, 2).map(w => [...w][0]).join('').toUpperCase())
</script>
<template>
  <span class="av" :style="{ width: size + 'px', height: size + 'px', fontSize: size * 0.38 + 'px', background: `hsl(${hue} 45% 38%)` }" aria-hidden="true">
    <img v-if="photo && !group" class="ph" :src="'data:image/jpeg;base64,' + photo" alt="" />
    <Users v-else-if="group" :size="size * 0.5" :stroke-width="1.75" />
    <template v-else>{{ initials }}</template>
    <ShieldAlert v-if="shield" class="sh" :size="size * 0.34" :stroke-width="2.25" />
  </span>
</template>
<style scoped>
.av { position: relative; flex: none; border-radius: 50%; display: grid; place-items: center; color: #fff; font-weight: 600; }
.ph { width: 100%; height: 100%; border-radius: 50%; object-fit: cover; }
.sh { position: absolute; right: -3px; bottom: -3px; padding: 2px; border-radius: 50%; background: var(--bg); color: var(--warn); box-sizing: content-box; }
</style>
