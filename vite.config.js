import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { readFileSync } from 'node:fs'

const { version } = JSON.parse(readFileSync(new URL('./package.json', import.meta.url)))

export default defineConfig({
  plugins: [vue()],
  define: { __APP_VERSION__: JSON.stringify(version) },
  build: { target: 'es2022', sourcemap: false },
  // Mesh tests use real timers; slow CI runners need more than Vitest's 5 s default per test.
  test: { environment: 'node', testTimeout: 60000 }
})
