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
  durationMs: 4000,
  intervalMs: 260,
  style: 'ring',
  accent: '#22C55E',
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

  const runHelper = (extraArgs) =>
    new Promise((resolve) => {
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

      let stdout = ''
      let stderr = ''
      const timer = setTimeout(() => {
        try { child.kill() } catch { /* already gone */ }
      }, 20000)

      child.stdout.setEncoding('utf8')
      child.stdout.on('data', (chunk) => { stdout += chunk })
      child.stderr.setEncoding('utf8')
      child.stderr.on('data', (chunk) => { stderr += chunk })
      child.on('error', (error) => {
        clearTimeout(timer)
        resolve({ ok: false, error: `spawn-failed: ${error.message}` })
      })
      child.on('close', (code) => {
        clearTimeout(timer)
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

  if (cfg.testOnLoad) {
    setTimeout(() => {
      void runHelper([
        '-DurationMs', String(2500),
        '-IntervalMs', String(cfg.intervalMs),
        '-Style', String(cfg.style),
        '-Accent', normalizeAccent(cfg.accent),
      ]).then((result) => writeLog({ kind: 'test-on-load', result }))
    }, 1500)
  }

  let flashing = false
  let queuedAt = 0

  const flash = async (reason) => {
    if (flashing) {
      queuedAt = Date.now()
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
      const result = await runHelper(args)
      writeLog({ kind: 'flash', reason, onlyWhenBackground: !!cfg.onlyWhenBackground, result })
    } finally {
      flashing = false
      if (queuedAt && Date.now() - queuedAt < 1500) {
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

  writeLog({ kind: 'loaded', iconPath, style: cfg.style, onlyWhenBackground: !!cfg.onlyWhenBackground })
}
