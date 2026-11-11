import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const mod = await import('../lib/index.js')

assert.equal(mod.name, 'dsh-done-flash')
assert.ok(Array.isArray(mod.inject))
assert.equal(typeof mod.apply, 'function')

const dir = mkdtempSync(join(tmpdir(), 'done-flash-'))
const logFile = join(dir, 'done-flash.log')

const listeners = new Map()
const ctx = {
  on(event, handler) {
    listeners.set(event, handler)
    return () => listeners.delete(event)
  },
}

mod.apply(ctx, {
  durationMs: 1600,
  intervalMs: 220,
  restoreOnLoad: false,
  logFile,
})

assert.ok(listeners.has('session/event'), 'listener registered')

const handler = listeners.get('session/event')

// A finished turn on a top-level session should trigger a flash.
handler({ id: 'session-test' }, { type: 'turn/end' })
await new Promise((resolve) => setTimeout(resolve, 4500))

// Subagent turns are skipped by default.
handler({ id: 'session-sub', parentSession: 'session-test' }, { type: 'turn/end' })

// Non-turn events are ignored.
handler({ id: 'session-test' }, { type: 'step/end' })

const lines = readFileSync(logFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
const loaded = lines.find((line) => line.kind === 'loaded')
const flashes = lines.filter((line) => line.kind === 'flash')

assert.ok(loaded, 'loaded record written')
assert.equal(flashes.length, 1, `expected exactly one flash, got ${flashes.length}`)
const [flash] = flashes
assert.equal(flash.reason, 'turn/end')
assert.ok(flash.result && typeof flash.result === 'object', 'helper result recorded')

const result = flash.result
console.log('helper result:', JSON.stringify(result))

if (result.skipped === 'foreground') {
  console.log('NOTE: DeepSeek Harness had focus, so the flash was correctly skipped.')
} else {
  assert.equal(result.ok, true, `helper failed: ${JSON.stringify(result)}`)
  assert.equal(result.failed, 0, 'no failed icon updates')
  assert.ok(result.toggles >= 4, `expected several toggles, got ${result.toggles}`)
  assert.ok(Number.isInteger(result.uid), 'resolved a tray icon id')
  assert.equal(result.style, 'blink')
}

rmSync(dir, { recursive: true, force: true })
console.log('plugin self-test passed')
