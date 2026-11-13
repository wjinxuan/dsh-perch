import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

/** Local endpoint of the screen-level helper (see overlay/main.swift). */
const HELPER_URL = 'http://127.0.0.1:47823/state'

/** Defaults applied when the patch leaves a field out. */
const DEFAULT_TEXT = { zh: '任务完成', en: 'Task complete' }

/**
 * Notification preferences are the only part of the config the helper needs.
 * The Client half cannot read a bundle row's config, so this half forwards it.
 * @param {unknown} config - resolved row config from `cordis.patch.yml`.
 * @returns the settings payload the helper decodes.
 */
function readSettings(config) {
  const source = config && typeof config === 'object' ? config : {}
  const notify = source.notify && typeof source.notify === 'object' ? source.notify : {}
  const text = source.text && typeof source.text === 'object' ? source.text : {}
  const pick = (value, fallback) => (typeof value === 'string' && value.trim() !== '' ? value : fallback)
  return {
    kind: 'settings',
    notify: { system: notify.system !== false, voice: notify.voice !== false },
    text: { zh: pick(text.zh, DEFAULT_TEXT.zh), en: pick(text.en, DEFAULT_TEXT.en) },
  }
}

/**
 * Host half of the Perch bundle.
 *
 * The island is drawn on the screen's notch band by a separate,
 * dependency-free AppKit helper that this half launches. The Client half posts
 * presentation-ready JSON to it; this half forwards the notification settings
 * from the bundle patch, so a helper restart heals itself within 30 seconds.
 *
 * The helper is optional: without it (`config.overlay: false`, a non-macOS
 * host, or a missing bundle) nothing is drawn and nothing else changes.
 */
export function apply(ctx, config) {
  if (process.platform !== 'darwin') return
  if (config && config.overlay === false) return

  const app = fileURLToPath(new URL('./overlay/PerchOverlay.app', import.meta.url))
  if (!existsSync(app)) {
    ctx.logger?.warn?.('perch: overlay helper missing at ' + app)
    return
  }
  if (typeof fetch !== 'function') {
    ctx.logger?.warn?.('perch: this host has no global fetch; overlay settings are not forwarded')
    return
  }

  const settings = readSettings(config)

  // `open -g` reuses a running copy (it is the same bundle) and never steals
  // focus; the helper is an accessory app with no Dock icon.
  try {
    const child = spawn('open', ['-g', app], { detached: true, stdio: 'ignore' })
    child.on('error', () => {})
    child.unref()
  } catch {
    // Launching is best effort; the settings POST simply fails below.
  }

  const post = () => {
    void fetch(HELPER_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: JSON.stringify(settings),
    }).catch(() => {})
  }

  ctx.effect(() => {
    // The helper needs a moment to start listening, and may be restarted
    // later; a few early retries plus a slow heartbeat covers both.
    const retries = [300, 1000, 2500, 5000].map((delay) => setTimeout(post, delay))
    const heartbeat = setInterval(post, 30_000)
    return () => {
      for (const timer of retries) clearTimeout(timer)
      clearInterval(heartbeat)
    }
  }, 'perch: overlay settings')
}
