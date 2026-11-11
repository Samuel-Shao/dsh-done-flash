import { spawn } from 'node:child_process'
import { existsSync, appendFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-done-flash'

export const inject = []

const here = dirname(fileURLToPath(import.meta.url))
const HELPER = join(here, 'tray-flash.ps1')

const DEFAULTS = {
  enabled: true,
  onlyWhenBackground: true,
  skipSubagents: true,
  untilForeground: true,
  maxDurationMs: 0,
  durationMs: 4000,
  intervalMs: 460,
  style: 'blink',
  accent: '#22C55E',
  appTitle: 'DeepSeek Harness',
  iconPath: '',
  restoreOnLoad: true,
  logFile: '',
  testOnLoad: false,
}

function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh')
}

function defaultIconPath() {
  const exeDir = dirname(process.execPath)
  const candidates = [
    join(exeDir, 'resources', 'tray.ico'),
    join(process.env.LOCALAPPDATA || '', 'Programs', 'DeepSeek Harness', 'resources', 'tray.ico'),
  ]
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate
  }
  return ''
}

function normalizeAccent(value) {
  const raw = String(value || '').trim().replace(/^#/, '')
  return /^[0-9a-fA-F]{6}$/.test(raw) ? raw.toUpperCase() : '22C55E'
}

export function apply(ctx, config) {
  const cfg = { ...DEFAULTS, ...(config || {}) }
  if (!cfg.enabled) return

  const iconPath = cfg.iconPath || defaultIconPath()
  const logFile = cfg.logFile || join(dshHome(), 'log', 'dsh-done-flash.log')

  const writeLog = (entry) => {
    try {
      mkdirSync(dirname(logFile), { recursive: true })
      appendFileSync(logFile, JSON.stringify({ time: new Date().toISOString(), ...entry }) + '\n')
    } catch {
      // Logging must never take the notification path down.
    }
  }

  const runHelper = (extraArgs, options = {}) =>
    new Promise((resolve) => {
      const { onChild, timeoutMs = 20000 } = options
      if (!iconPath || !existsSync(iconPath)) {
        resolve({ ok: false, error: 'icon-path-missing', iconPath })
        return
      }
      let child
      try {
        child = spawn(
          process.env.SystemRoot ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe') : 'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-WindowStyle', 'Hidden',
            '-File', HELPER,
            '-IconPath', iconPath,
            ...extraArgs,
          ],
          { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
        )
      } catch (error) {
        resolve({ ok: false, error: `spawn-failed: ${error.message}` })
        return
      }
      if (onChild) onChild(child)

      let stdout = ''
      let stderr = ''
      const timer = timeoutMs > 0
        ? setTimeout(() => {
            try { child.kill() } catch { /* already gone */ }
          }, timeoutMs)
        : null

      child.stdout.setEncoding('utf8')
      child.stdout.on('data', (chunk) => { stdout += chunk })
      child.stderr.setEncoding('utf8')
      child.stderr.on('data', (chunk) => { stderr += chunk })
      child.on('error', (error) => {
        if (timer) clearTimeout(timer)
        resolve({ ok: false, error: `spawn-failed: ${error.message}` })
      })
      child.on('close', (code) => {
        if (timer) clearTimeout(timer)
        let parsed = null
        for (const line of stdout.trim().split(/\r?\n/).reverse()) {
          const text = line.trim()
          if (!text.startsWith('{')) continue
          try { parsed = JSON.parse(text); break } catch { /* keep looking */ }
        }
        resolve({ ...(parsed || { ok: false, error: 'no-helper-output', stdout: stdout.slice(0, 400), stderr: stderr.slice(0, 400) }), exitCode: code })
      })
    })

  if (cfg.restoreOnLoad) {
    void runHelper(['-RestoreOnly']).then((result) => writeLog({ kind: 'restore-on-load', result }))
  }

  const testArgs = [
    '-DurationMs', String(2500),
    '-IntervalMs', String(cfg.intervalMs),
    '-Style', String(cfg.style),
    '-Accent', normalizeAccent(cfg.accent),
  ]

  if (cfg.testOnLoad && typeof ctx.effect === 'function') {
    ctx.effect(() => {
      const timer = setTimeout(() => {
        void runHelper(testArgs).then((result) => writeLog({ kind: 'test-on-load', result }))
      }, 1500)
      return () => clearTimeout(timer)
    })
  }

  // One live flash at a time. In untilForeground mode the child keeps blinking
  // for as long as it takes the user to bring the app back to the front, so it
  // is tracked here and stopped when the plugin is unloaded.
  let activeChild = null
  let flashing = false
  let queuedAt = 0

  const stopActive = () => {
    if (!activeChild) return
    const child = activeChild
    activeChild = null
    try { child.kill() } catch { /* already gone */ }
    // A killed helper can leave the tray icon on the hidden frame.
    void runHelper(['-RestoreOnly'])
  }

  if (typeof ctx.effect === 'function') ctx.effect(() => () => stopActive())
  const flash = async (reason) => {
    if (flashing) {
      queuedAt = Date.now()
      if (cfg.untilForeground) writeLog({ kind: 'flash-merged', reason })
      return
    }
    flashing = true
    try {
      const args = [
        '-DurationMs', String(Math.max(600, Number(cfg.durationMs) || DEFAULTS.durationMs)),
        '-IntervalMs', String(Math.max(80, Number(cfg.intervalMs) || DEFAULTS.intervalMs)),
        '-Style', String(cfg.style).toLowerCase(),
        '-Accent', normalizeAccent(cfg.accent),
      ]
      if (cfg.onlyWhenBackground) args.push('-RequireBackground')
      const cap = Math.max(0, Number(cfg.maxDurationMs) || 0)
      if (cfg.untilForeground) {
        args.push('-UntilForeground', '-AppTitle', String(cfg.appTitle || DEFAULTS.appTitle))
        if (cap > 0) args.push('-MaxDurationMs', String(cap))
      }
      // In untilForeground mode the helper runs until the user comes back, so
      // only the optional safety cap (plus a minute of slack) bounds it.
      const timeoutMs = cfg.untilForeground ? (cap > 0 ? cap + 60000 : 0) : Math.max(600, Number(cfg.durationMs) || DEFAULTS.durationMs) + 30000
      const result = await runHelper(args, { onChild: (child) => { activeChild = child }, timeoutMs })
      activeChild = null
      writeLog({
        kind: 'flash',
        reason,
        mode: cfg.untilForeground ? 'until-foreground' : 'timed',
        onlyWhenBackground: !!cfg.onlyWhenBackground,
        result,
      })
      // The helper was interrupted (plugin reload, timeout, crash) while it may
      // have left the tray icon on the hidden frame: put the real icon back.
      if (result && result.error) {
        const restored = await runHelper(['-RestoreOnly'])
        writeLog({ kind: 'restore-after-abort', result: restored })
      }
    } finally {
      flashing = false
      if (queuedAt && Date.now() - queuedAt < 1500 && !cfg.untilForeground) {
        const since = queuedAt
        queuedAt = 0
        setTimeout(() => { void flash(`queued@${since}`) }, 300)
      } else {
        queuedAt = 0
      }
    }
  }

  ctx.on('session/event', (session, event) => {
    const type = event && event.type
    if (type !== 'turn/end') return
    if (cfg.skipSubagents && session && session.parentSession) return
    void flash('turn/end')
  })

  writeLog({
    kind: 'loaded',
    iconPath,
    style: cfg.style,
    onlyWhenBackground: !!cfg.onlyWhenBackground,
    skipSubagents: !!cfg.skipSubagents,
    untilForeground: !!cfg.untilForeground,
    maxDurationMs: Number(cfg.maxDurationMs) || 0,
  })
}
