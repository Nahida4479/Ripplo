import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { createServer } from 'node:net'
import { mkdirSync, readdirSync, rmSync } from 'node:fs'
import { deflateSync, crc32 } from 'node:zlib'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PW_DIR = process.env.PW_DIR || '/tmp/claude-1000/-home-scybula--claude-spares-spare-gPGTG6/d46f7fcd-34dc-4003-868b-569c11b0186f/scratchpad/pw'
const OUT = resolve(process.env.REF_OUT || join(ROOT, 'test/goldens/ref'))
const { chromium } = createRequire(join(PW_DIR, 'x.js'))('playwright')

const sleep = ms => new Promise(r => setTimeout(r, ms))
const freePort = () => new Promise((res, rej) => {
  const s = createServer()
  s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => res(port)) })
  s.on('error', rej)
})
const at = (day, hm) => new Date(`2026-01-${day}T${hm}+01:00`)

const SEED = () => {
  window.__m = async () => ({
    api: await import('/src/core/api.js'),
    ui: await import('/src/components/ui.js'),
    theme: await import('/src/services/theme.js'),
    lock: await import('/src/services/lock.js')
  })
  const p = new URLSearchParams(location.search).get('profile') || 'default'
  let h = 1779033703
  for (const c of p) h = Math.imul(h ^ c.charCodeAt(0), 3432918353)
  let s = h >>> 0
  const rnd = () => {
    s = (s + 0x6D2B79F5) | 0
    let t = Math.imul(s ^ (s >>> 15), 1 | s)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
  Math.random = rnd
  crypto.getRandomValues = a => {
    const u = new Uint8Array(a.buffer, a.byteOffset, a.byteLength)
    for (let i = 0; i < u.length; i++) u[i] = (rnd() * 256) | 0
    return a
  }
  const st = document.createElement('style')
  st.textContent = 'html:root{--sat:24px!important;--sab:16px!important}*{caret-color:transparent!important}'
  document.addEventListener('DOMContentLoaded', () => document.head.appendChild(st))
}

function png(w, h) {
  const raw = Buffer.alloc((w * 3 + 1) * h)
  for (let y = 0; y < h; y++) {
    const o = y * (w * 3 + 1)
    for (let x = 0; x < w; x++) {
      raw[o + 1 + x * 3] = Math.round(x * 255 / w)
      raw[o + 2 + x * 3] = Math.round(y * 255 / h)
      raw[o + 3 + x * 3] = 140
    }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
    const td = Buffer.concat([Buffer.from(type), data])
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td))
    return Buffer.concat([len, td, crc])
  }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
}

const run = (page, fn, arg = null) => page.evaluate(`(async()=>{const m=await window.__m();return (${fn.toString()})(m,${JSON.stringify(arg)})})()`)
async function until(page, fn, arg, ms = 30000) {
  const end = Date.now() + ms
  while (!(await run(page, fn, arg))) {
    if (Date.now() > end) throw new Error('timeout waiting for ' + fn.toString().slice(0, 90))
    await sleep(150)
  }
}

let shots = 0
const unreachable = []
const written = []

async function settle(page) {
  await page.evaluate(() => { document.activeElement?.blur?.(); return document.fonts.ready })
  await sleep(250)
}
async function shot(page, name, { pre, themes = ['dark', 'light'], toast = false } = {}) {
  for (const th of themes) {
    if (!toast) await toastGone(page)
    await run(page, (m, v) => { m.theme.theme.mode = v }, th)
    if (pre) await pre(page)
    await settle(page)
    await page.screenshot({ path: join(OUT, `${name}-${th}.png`), animations: 'disabled', caret: 'hide' })
    written.push(`${name}-${th}.png`)
    shots++
  }
  await run(page, m => { m.theme.theme.mode = 'dark' })
}
async function step(name, fn) {
  try { await fn() } catch (e) {
    unreachable.push(`${name}: ${String(e.message).split('\n')[0]}`)
    console.error('UNREACHABLE', name, '-', String(e.message).split('\n')[0])
  }
}
const toastGone = page => until(page, m => !m.ui.ui.toastText, null, 8000).catch(() => {})
const tab = (page, label) => page.click(`nav.tabbar a[aria-label="${label}"]`)
const contactId = (page, name) => run(page, (m, n) => Object.values(m.api.state.contacts).find(c => c.name === n)?.id ?? null, name)
const section = (page, title) => page.evaluate(t => {
  const main = document.querySelector('main.page')
  const h = [...main.querySelectorAll('h2.section')].find(x => x.textContent.trim().startsWith(t))
  main.scrollTop += h.getBoundingClientRect().top - 60
}, title)

async function openProfile(ctx, base, profile, extra = '') {
  const page = await ctx.newPage()
  await page.goto(`${base}/?profile=${profile}${extra}`)
  await page.waitForSelector('input.field, nav.tabbar, .center', { timeout: 30000 })
  return page
}
async function onboard(page, name) {
  await page.fill('input.field', name)
  await page.click('button.btn:not(.ghost)')
  await page.waitForSelector('nav.tabbar', { timeout: 30000 })
}

async function main() {
  mkdirSync(OUT, { recursive: true })
  for (const f of readdirSync(OUT)) if (f.endsWith('.png')) rmSync(join(OUT, f))

  const port = await freePort()
  const base = `http://127.0.0.1:${port}`
  const vite = spawn('npm', ['run', 'dev', '--', '--port', String(port), '--strictPort', '--host', '127.0.0.1'], { cwd: ROOT, detached: true, stdio: 'ignore' })
  process.on('SIGINT', () => { try { process.kill(-vite.pid) } catch {} process.exit(1) })
  for (let i = 0; ; i++) {
    try { if ((await fetch(base)).ok) break } catch {}
    if (i > 120) throw new Error('vite did not start')
    await sleep(500)
  }

  const browser = await chromium.launch({ args: ['--font-render-hinting=none', '--disable-lcd-text', '--force-color-profile=srgb', '--disable-gpu'] })
  try {
    const ctx = await browser.newContext({
      viewport: { width: 412, height: 915 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true,
      locale: 'en-US', timezoneId: 'Europe/Warsaw', colorScheme: 'dark', reducedMotion: 'reduce', serviceWorkers: 'block'
    })
    await ctx.route(u => !['127.0.0.1', 'localhost'].includes(u.hostname) && !['data:', 'blob:'].includes(u.protocol), r => r.abort())
    await ctx.addInitScript(SEED)
    await ctx.clock.install({ time: at(14, '20:50:05') })

    const warm = await ctx.newPage()
    await warm.goto(`${base}/?profile=warm`)
    await warm.waitForSelector('input.field', { timeout: 60000 })
    await sleep(1500)
    await warm.reload()
    await warm.waitForSelector('input.field', { timeout: 60000 })
    await warm.close()

    const gate = await ctx.newPage()
    const PERMS = {
      needed: { bluetooth: 'prompt', wifi: 'prompt', notifications: 'prompt', microphone: 'prompt', fullscreen: 'prompt', battery: 'prompt' },
      partial: { bluetooth: 'granted', wifi: 'denied', notifications: 'prompt', microphone: 'granted', fullscreen: 'prompt', battery: 'prompt' },
      optional: { bluetooth: 'granted', wifi: 'granted', notifications: 'granted', microphone: 'prompt', fullscreen: 'prompt', battery: 'prompt' }
    }
    let perms = PERMS.needed
    await gate.route('**/src/services/permissions.js*', async r => {
      const res = await r.fetch()
      const body = (await res.text()).replace(/return \{ bluetooth: 'granted'[^\n]*\}/, `return ${JSON.stringify(perms)}`)
      await r.fulfill({ response: res, body })
    })
    for (const [k, v] of Object.entries(PERMS)) {
      await step('gate-' + k, async () => {
        perms = v
        await gate.goto(`${base}/?profile=gate`)
        await gate.waitForSelector('.chip')
        await shot(gate, 'gate-' + k)
      })
    }
    await gate.close()

    const alice = await openProfile(ctx, base, 'alice')
    await step('onboarding', async () => {
      await shot(alice, 'onboarding-empty')
      await alice.fill('input.field', 'Alice')
      await shot(alice, 'onboarding-filled')
    })
    await onboard(alice, 'Alice')
    await sleep(500)

    await step('chats-empty', () => shot(alice, 'chats-empty'))
    await step('addcontact-code', async () => {
      await alice.click('button[aria-label="Add contact"]')
      await alice.waitForSelector('.sheet img.qr')
      await sleep(300)
      await shot(alice, 'addcontact-code')
    })
    await step('addcontact-scan', async () => {
      await alice.click('.sheet .seg button:nth-child(2)')
      await sleep(600)
      await shot(alice, 'toast-camera', { toast: true, pre: p => run(p, m => m.ui.toast('Camera not available')) })
      await toastGone(alice)
      await shot(alice, 'addcontact-scan')
    })
    await step('addcontact-paste-empty', async () => {
      await alice.click('.sheet .seg button:nth-child(3)')
      await shot(alice, 'addcontact-paste-empty')
    })
    await alice.click('.sheet button.btn.ghost.block')
    await step('newchat-empty', async () => {
      await alice.click('button[aria-label="New chat"]')
      await shot(alice, 'newchat-empty')
      await alice.click('.sheet .actions .btn.ghost')
    })
    await step('people-empty', async () => {
      await tab(alice, 'Find people')
      await sleep(300)
      await shot(alice, 'people-empty')
      await tab(alice, 'Chats')
    })

    const bob = await openProfile(ctx, base, 'bob')
    await onboard(bob, 'Bob')
    const carol = await openProfile(ctx, base, 'carol')
    await onboard(carol, 'Carol')
    const bobLink = await run(bob, m => m.api.myInviteLink())
    const carolLink = await run(carol, m => m.api.myInviteLink())
    await carol.close({ runBeforeUnload: true })
    await until(alice, m => m.api.state.neighbors.length === 1 && m.api.state.neighbors[0].card?.name === 'Bob', null, 60000)
    await until(bob, m => m.api.state.neighbors.length === 1, null, 60000)

    await step('add-bob', async () => {
      await alice.click('button[aria-label="Add contact"]')
      await alice.click('.sheet .seg button:nth-child(3)')
      await alice.fill('.sheet input.field', bobLink)
      await shot(alice, 'addcontact-paste-filled')
      await alice.click('.sheet .actions .btn:not(.ghost)')
      await alice.waitForSelector('main .card.pad')
    })
    await until(alice, m => { const c = Object.values(m.api.state.contacts).find(x => x.name === 'Bob'); return c && c.cardAck && c.verification !== 'none' }, null, 60000).catch(e => unreachable.push('bob verification: ' + e.message))
    await until(bob, m => Object.values(m.api.state.contacts).some(x => x.name === 'Alice'), null, 30000)
    const bobId = await contactId(alice, 'Bob')
    const aliceId = await contactId(bob, 'Alice')
    await toastGone(alice)
    await step('contact-verified', () => shot(alice, 'contact-verified'))

    await ctx.clock.setSystemTime(at(14, '21:05:05'))
    await run(alice, (m, id) => m.api.sendText(id, 'Hey Bob, are you around tomorrow?'), bobId)
    await sleep(1500)
    await ctx.clock.setSystemTime(at(14, '21:07:05'))
    await run(bob, (m, id) => m.api.sendText(id, 'Yes, after 10. Coffee?'), aliceId)
    await sleep(1500)
    await ctx.clock.setSystemTime(at(15, '10:20:05'))
    await sleep(3500)
    await until(alice, m => m.api.state.neighbors.length === 1, null, 20000)
    await until(bob, m => m.api.state.neighbors.length === 1, null, 20000)
    await run(alice, (m, id) => m.api.sendText(id, 'Sounds good. Meet at the square?'), bobId)
    await sleep(800)
    await ctx.clock.setSystemTime(at(15, '10:21:05'))
    await run(bob, (m, id) => m.api.sendText(id, 'On my way.'), aliceId)
    await sleep(1200)
    await ctx.clock.setSystemTime(at(15, '10:24:05'))
    await run(alice, async (m, id) => {
      const first = m.api.state.messages[id].find(x => x.text === 'Yes, after 10. Coffee?')
      await m.api.sendText(id, 'Coffee at 10:30 then', first.id)
    }, bobId)
    await sleep(1200)

    await alice.evaluate(id => { location.hash = '#/chat/' + id }, bobId)
    await alice.waitForSelector('.log .msg')
    await sleep(500)

    await step('chat-staged', async () => {
      await ctx.clock.setSystemTime(at(15, '10:26:05'))
      await alice.setInputFiles('input[type=file]', { name: 'photo.png', mimeType: 'image/png', buffer: png(240, 160) })
      await alice.waitForSelector('.staged .thumb img')
      await sleep(300)
      await shot(alice, 'chat-staged')
      await alice.click('button[aria-label="Send"]')
      await alice.waitForSelector('.log img.media', { timeout: 15000 })
      await until(alice, (m, id) => m.api.state.messages[id].filter(x => x.from === 'me').every(x => x.status === 'delivered'), bobId, 20000).catch(() => {})
      await sleep(800)
    })
    await run(alice, (m, id) => {
      m.api.state.messages[id].push({ id: 'v0ice0000000000000000000000000001', chatId: id, from: id, ts: new Date('2026-01-15T10:27:05+01:00').getTime(), status: 'received', att: { kind: 'voice', mime: 'audio/webm', size: 4000, duration: 12, wave: [20, 60, 120, 200, 255, 180, 90, 40, 150, 220, 130, 60, 30, 90, 170, 240, 200, 110, 50, 20, 80, 140, 210, 160, 70, 30, 100, 190, 230, 120, 60, 25, 70, 130, 180, 90, 45, 20, 60, 110] } })
    }, bobId)
    await sleep(500)
    await step('chat-messages', async () => {
      await shot(alice, 'chat-messages')
      await run(alice, m => { m.theme.theme.accent = '#1e3a8a'; m.theme.theme.gradient = '#5b2ea6' })
      await shot(alice, 'chat-messages-accent')
      await run(alice, m => { m.theme.theme.accent = '#4f9cf9'; m.theme.theme.gradient = '' })
    })
    await step('chat-typing', async () => {
      await run(alice, (m, id) => { m.api.state.typing[id] = ['x'] }, bobId)
      await sleep(300)
      await shot(alice, 'chat-typing')
      await run(alice, (m, id) => { m.api.state.typing[id] = [] }, bobId)
    })
    await step('chat-composer', async () => {
      await alice.fill('footer.comp textarea', 'See you at the square in ten minutes')
      await shot(alice, 'chat-composer')
      await alice.fill('footer.comp textarea', '')
    })
    await step('chat-reply', async () => {
      const b = await alice.locator('.msg.in .bubble').filter({ hasText: 'On my way.' }).boundingBox()
      await alice.mouse.move(b.x + 20, b.y + b.height / 2)
      await alice.mouse.down()
      for (let i = 1; i <= 8; i++) await alice.mouse.move(b.x + 20 + i * 10, b.y + b.height / 2)
      await alice.mouse.up()
      await alice.waitForSelector('.replybar', { timeout: 3000 })
      await shot(alice, 'chat-reply')
      await alice.click('.replybar button')
    })
    await step('chat-staged-two', async () => {
      await alice.setInputFiles('input[type=file]', [
        { name: 'a.png', mimeType: 'image/png', buffer: png(240, 160) },
        { name: 'b.png', mimeType: 'image/png', buffer: png(120, 200) }
      ])
      await alice.waitForSelector('.staged .thumb img')
      await alice.fill('footer.comp textarea', 'Two photos')
      await shot(alice, 'chat-staged-two')
      await alice.evaluate(() => document.querySelectorAll('.staged .rm').forEach(b => b.click()))
      await alice.fill('footer.comp textarea', '')
    })

    await alice.evaluate(() => { location.hash = '#/' })
    await alice.waitForSelector('nav.tabbar')
    await step('add-carol', async () => {
      await ctx.clock.setSystemTime(at(15, '10:28:05'))
      await alice.click('button[aria-label="Add contact"]')
      await alice.click('.sheet .seg button:nth-child(3)')
      await alice.fill('.sheet input.field', carolLink)
      await alice.click('.sheet .actions .btn:not(.ghost)')
      await alice.waitForSelector('main .card.pad')
      await toastGone(alice)
    })
    const carolId = await contactId(alice, 'Carol')
    await step('contact-unverified', async () => {
      await sleep(600)
      await shot(alice, 'contact-unverified')
    })
    await step('confirm-sure', async () => {
      await alice.click('button.btn.ghost:has-text("I\'m sure it\'s them")')
      await alice.waitForSelector('.scrim .sheet')
      await shot(alice, 'confirm-sure')
      await alice.click('.sheet .actions .btn.ghost')
    })
    await step('confirm-delete', async () => {
      await alice.click('button.btn.danger')
      await alice.waitForSelector('.scrim .sheet')
      await shot(alice, 'confirm-delete')
      await alice.click('.sheet .actions .btn.ghost')
    })
    await step('addcontact-verify', async () => {
      await alice.click('button.btn:has-text("Verify with QR code")')
      await alice.waitForSelector('.sheet .view')
      await sleep(600)
      await shot(alice, 'addcontact-verify')
      await alice.click('.sheet button.btn.ghost.block')
    })

    await alice.evaluate(id => { location.hash = '#/chat/' + id }, carolId)
    await alice.waitForSelector('.log')
    await sleep(600)
    await step('chat-empty', () => shot(alice, 'chat-empty'))
    await run(alice, (m, id) => {
      const t = h => new Date(`2026-01-15T${h}+01:00`).getTime()
      m.api.state.messages[id].push(
        { id: 'c0000000000000000000000000000001', chatId: id, from: 'me', ts: t('10:28:20'), status: 'delivered', hops: 1, text: 'Hi Carol, this is Alice.' },
        { id: 'c0000000000000000000000000000002', chatId: id, from: 'me', ts: t('10:29:10'), status: 'sending', text: 'Are you coming to the meetup?' },
        { id: 'c0000000000000000000000000000003', chatId: id, from: 'me', ts: t('10:29:30'), status: 'out_of_range', text: 'Let me know when you are close.' },
        { id: 'c0000000000000000000000000000004', chatId: id, from: 'me', ts: t('10:29:40'), status: 'failed', text: 'Sending this one failed.' },
        { id: 'c0000000000000000000000000000005', chatId: id, from: 'system', ts: t('10:29:50'), status: 'received', text: 'Carol changed her safety number.' }
      )
    }, carolId)
    await sleep(400)
    await step('chat-unverified', () => shot(alice, 'chat-unverified'))

    await step('chat-group', async () => {
      await alice.evaluate(() => { location.hash = '#/' })
      await alice.waitForSelector('nav.tabbar')
      await alice.click('button[aria-label="New chat"]')
      await shot(alice, 'newchat-contacts')
      await alice.click('.sheet .seg button:nth-child(2)')
      await alice.fill('.sheet input.field', 'Trip crew')
      await alice.click('.sheet .list-row:has-text("Bob")')
      await alice.click('.sheet .list-row:has-text("Carol")')
      await shot(alice, 'newchat-group')
      await ctx.clock.setSystemTime(at(15, '10:29:55'))
      await alice.click('.sheet .actions .btn:not(.ghost)')
      await alice.waitForSelector('.log')
      await sleep(400)
      const gid = await run(alice, m => m.api.state.chats.find(c => c.type === 'group').id)
      await run(alice, (m, id) => m.api.sendText(id, 'Meeting point is the old square.'), gid)
      await sleep(800)
      await shot(alice, 'chat-group')
    })

    await step('chats-list', async () => {
      await alice.evaluate(() => { location.hash = '#/' })
      await alice.waitForSelector('nav.tabbar')
      await ctx.clock.setSystemTime(at(15, '10:30:05'))
      await run(bob, (m, id) => m.api.sendText(id, 'See you soon'), aliceId)
      await until(alice, m => m.api.state.chats.some(c => c.unread), null, 15000)
      await sleep(400)
      await shot(alice, 'chats-list')
      await run(alice, m => { m.theme.theme.accent = '#1e3a8a'; m.theme.theme.gradient = '#5b2ea6' })
      await shot(alice, 'chats-list-accent')
      await run(alice, m => { m.theme.theme.accent = '#4f9cf9'; m.theme.theme.gradient = '' })
    })

    const dave = await openProfile(ctx, base, 'dave')
    await onboard(dave, 'Dave')
    await until(alice, m => m.api.state.neighbors.length === 2 && m.api.state.neighbors.every(n => n.card), null, 60000)
    await until(dave, m => m.api.state.neighbors.length >= 1 && m.api.state.neighbors.some(n => n.card), null, 60000)
    await step('people-nearby', async () => {
      await tab(alice, 'Find people')
      await sleep(500)
      await shot(alice, 'people-nearby')
    })
    await step('confirm-invite', async () => {
      await alice.locator('.row', { hasText: 'Dave' }).locator('button.btn.sm').click()
      await alice.waitForSelector('.scrim .sheet')
      await shot(alice, 'confirm-invite')
      await alice.click('.sheet .actions .btn.ghost')
    })
    await step('dave-invites', async () => {
      await tab(dave, 'Find people')
      await dave.locator('.row', { hasText: 'Alice' }).locator('button.btn.sm').click()
      await dave.click('.sheet .actions .btn:not(.ghost)')
      await until(alice, m => Object.values(m.api.state.contacts).some(c => c.name === 'Dave' && c.request === 'in'), null, 20000)
      await sleep(800)
      await toastGone(alice)
      await shot(alice, 'people-request')
      await tab(alice, 'Chats')
      await sleep(400)
      await shot(alice, 'chats-requests')
    })
    await step('people-mesh', async () => {
      await tab(alice, 'Find people')
      await alice.click('button[aria-label="Refresh"]')
      await until(alice, m => m.api.state.people.length > 0, null, 30000)
      await until(alice, m => !m.api.state.peopleRefreshing, null, 30000)
      await shot(alice, 'people-mesh')
    })

    await tab(alice, 'Settings')
    await alice.waitForSelector('h2.section')
    await run(alice, m => { m.api.state.update.latest = m.api.state.update.current; m.api.state.update.error = null; m.api.state.update.available = false })
    await step('settings', async () => {
      await shot(alice, 'settings-top')
      await run(alice, m => { m.theme.theme.accent = '#1e3a8a'; m.theme.theme.gradient = '#5b2ea6' })
      await shot(alice, 'settings-top-accent')
      await run(alice, m => { m.theme.theme.accent = '#4f9cf9'; m.theme.theme.gradient = '' })
      for (const [h, n] of [['Appearance', 'appearance'], ['Network', 'network'], ['Security', 'security'], ['Updates', 'updates'], ['About', 'about'], ['Contributors', 'contributors']]) {
        await section(alice, h)
        await shot(alice, 'settings-' + n)
        await alice.evaluate(() => { document.querySelector('main.page').scrollTop = 0 })
      }
    })
    await step('settings-dev', async () => {
      const row = alice.locator('.row[role=button]', { hasText: /^\s*Ripplo/ })
      await row.scrollIntoViewIfNeeded()
      for (let i = 0; i < 5; i++) await row.click({ delay: 20 })
      await alice.waitForSelector('h2.section:has-text("Developer")')
      await sleep(800)
      await toastGone(alice)
      await section(alice, 'Developer')
      await shot(alice, 'settings-dev', { pre: p => p.evaluate(() => document.querySelectorAll('.netinfo .devlog').forEach(e => { e.textContent = '–' })) })
      await alice.evaluate(() => { document.querySelector('main.page').scrollTop = 0 })
    })

    await step('share-text', async () => {
      await tab(alice, 'Chats')
      await run(alice, m => { m.ui.ui.share = { kind: 'text', text: 'Join me on Ripplo, a messenger that works without internet.' } })
      await shot(alice, 'share-text')
      await run(alice, m => { m.ui.ui.share = null })
    })
    await step('lock', async () => {
      await run(alice, m => { m.lock.lock.locked = true })
      await shot(alice, 'lock-locked')
      await run(alice, m => { m.lock.lock.locked = false })
    })
    await step('call-incoming', async () => {
      await run(alice, (m, id) => { m.api.state.call = { peer: id, status: 'ringing', dir: 'in' } }, bobId)
      await shot(alice, 'call-incoming')
      await run(alice, m => { m.api.state.call = null })
    })
    await step('call-active', async () => {
      const now = await alice.evaluate(() => Date.now())
      await run(alice, (m, a) => { m.api.state.call = { peer: a.id, status: 'active', dir: 'out', muted: false, startedAt: a.t - 83000, warn: 'out', stats: { sent: 4120, recv: 4098, played: 4090, errors: 0, track: 'live', audio: 'running', frames: 4098 } } }, { id: bobId, t: now + 1000 })
      await ctx.clock.pauseAt(new Date(now + 1000))
      await shot(alice, 'call-active')
      await ctx.clock.resume()
      await run(alice, (m, id) => { m.api.state.call = { peer: id, status: 'ringing', dir: 'out' } }, bobId)
      await shot(alice, 'call-outgoing')
      await run(alice, m => { m.api.state.call = null })
    })
  } finally {
    await browser.close()
    try { process.kill(-vite.pid) } catch {}
  }
  console.log(JSON.stringify({ shots, files: written.length, unreachable }, null, 2))
  process.exit(0)
}

main().catch(e => { console.error(e); process.exit(1) })
