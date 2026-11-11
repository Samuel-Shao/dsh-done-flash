# dsh-done-flash

Flash the DeepSeek Harness **tray whale** when a task finishes while the app sits in the background.

Windows has a hundred ways to nag you. This one is quiet: no popup, no sound, no toast that steals focus — the little whale in the system tray blinks green for a few seconds, then goes back to normal.

```
     ┌──────┐        ┌──────┐
     │ 🐋   │  ⟶⟶⟶   │▓🐋▓ │
     └──────┘        └──────┘
      idle            done (ring style)
```

## Why this plugin exists

DSH only shows its window-level attention cues while the window is in front of you. When you alt-tab to a browser and let an agent grind through a long task, nothing tells you it finished — you come back ten minutes later to a result that has been sitting there.

`dsh-done-flash` watches the session event stream, and on `turn/end` (a turn actually completed) lights up the tray icon:

- only when the DSH window is **not** in the foreground (configurable),
- never for hidden sub-agent conversations (configurable),
- with the whale still recognizable, not replaced by a generic badge.

## Requirements

| | |
| --- | --- |
| OS | Windows 10 / 11 |
| Host | DSH Desktop `>=0.2.0-rc.1 <0.3.0` |
| Runtime | the Windows PowerShell 5.1 that ships with Windows (no download) |
| Node | none at runtime — the plugin is dependency-free |

Linux/macOS hosts are not supported (the package declares `"os": ["win32"]`).

## Install

From the Web UI: **Settings → Plugins → Install** and point it at this package, or from a terminal:

```sh
dsh plugin --profile desktop add github:Samuel-Shao/dsh-done-flash
```

Local checkout / development:

```sh
dsh plugin --profile desktop add link:F:\path\to\dsh-done-flash
```

After installation the plugin appears as the bundle `dsh-done-flash`; restart the app if the host reports `restart-required`.

## Configuration

Every key is optional — defaults are shown.

```yaml
- id: dsh-done-flash
  name: dsh-done-flash
  config:
    enabled: true              # switch everything off without uninstalling
    onlyWhenBackground: true   # stay silent while the DSH window is focused
    skipSubagents: true        # ignore sub-agent conversations
    durationMs: 4000           # how long the flash runs
    intervalMs: 260            # blink half-period
    style: ring                # ring | badge | invert | blink
    accent: '#22C55E'          # any #RRGGBB
    iconPath: ''               # default: the app's own resources/tray.ico
    restoreOnLoad: true        # heal a stale flash icon after a crash
    logFile: ''                # default: $DSH_HOME/log/dsh-done-flash.log
    testOnLoad: false           # flash once 1.5 s after the plugin loads
```

Add the block to `~/.dsh/profiles/<profile>/cordis.patch.yml` (top level, matching the entry id). Changing the config does not need a reinstall.

### Styles

| style | look |
| --- | --- |
| `ring` *(default)* | the whole tile turns accent-coloured, whale inset — impossible to miss |
| `badge` | a filled dot in the bottom-right corner, whale untouched |
| `invert` | whale silhouette recoloured in the accent colour |
| `blink` | icon disappears and reappears (pure blink) |

`accent: '#22C55E'` (green) means *finished*; use `#F59E0B` for amber, `#3B82F6` for blue.

## How it works

1. `session/event` with `type === 'turn/end'` fires in the host process.
2. The plugin spawns `lib/tray-flash.ps1` hidden, passing the app's `resources/tray.ico`.
3. The helper finds the Electron tray message window (`Electron_NotifyIconHostWindow`) that belongs to the desktop process, locates the whale's `uID` with `Shell_NotifyIconGetRect`, and reads the PNG frames out of `tray.ico` (the app stores all seven as PNG).
4. It composites a highlighted twin at the exact DPI-matched size and alternates the two with `Shell_NotifyIcon(NIM_MODIFY)` for `durationMs`.
5. It always restores the original icon on the way out — plus once at load, in case a previous run was killed mid-flash.

No Electron API is touched: the tray icon is owned by the main process, and the plugin talks to the shell the same way the shell's own notification area does. Nothing is patched, nothing is injected into the renderer.

## Files

| path | role |
| --- | --- |
| `lib/index.js` | cordis plugin: event filter, debounce/queue, config, logging |
| `lib/tray-flash.ps1` | Win32 helper: tray lookup, frame extraction, compositing, blink loop |
| `test/plugin.test.mjs` | headless self-test with a fake `ctx` and a real flash |

## Self-test

```sh
node test/plugin.test.mjs
# plugin self-test passed
```

The test mounts the plugin on a fake context, emits `step/end` (must be ignored), a sub-agent `turn/end` (ignored), and a real `turn/end` (must flash), then prints the helper's JSON result.

## Log

```json
{"time":"2026-11-11T09:12:34.567Z","kind":"flash","reason":"turn/end","result":{"ok":true,"uid":3,"size":16,"dpi":96,"style":"ring","toggles":16,"failed":0}}
```

`$DSH_HOME/log/dsh-done-flash.log`, one JSON object per line.

## Troubleshooting

**Nothing flashes.** Check the log first: `loaded` means the plugin runs, `flash` means it fired. `error: "icon-path-missing"` means `iconPath` could not be resolved — set it by hand. `uids: []` means the helper found no tray icon: the app tray may have been re-created, or DSH is running elevated/under another user.

**It flashes with the window in front.** Your foreground window is not considered the DSH main window (for example a fullscreen game or an elevated window). Set `onlyWhenBackground: false` to always flash, or ignore it.

**The icon got stuck highlighted.** `restoreOnLoad` repairs that at the next start; or `node -e "..."` — simpler: remove and re-add the bundle.

**Antivirus complains about PowerShell.** The helper only calls `shell32`/`user32` exports this Windows version already ships. If your policy blocks PowerShell scripts, the plugin cannot flash (there is no Node-only path to another process's tray icon).

## License

MIT.
