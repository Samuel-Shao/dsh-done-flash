# dsh-done-flash

任务跑完时，让 DeepSeek Harness 的**托盘小鲸鱼闪一下**——前提是你正把 DSH 晾在后台。

Windows 上打扰人的办法有一百种，这个插件选最安静的一种：不弹窗、不响铃、不抢焦点，托盘里的鲸鱼图标按"有/无"节奏闪（就是微信那种闪法），**一直闪到你切回 DeepSeek Harness 为止**。

```
     ┌──────┐        ┌──────┐        ┌──────┐
     │ 🐋   │  ⟶⟶⟶   │      │  ⟶⟶⟶   │ 🐋   │
     └──────┘        └──────┘        └──────┘
      待机            消失            待机
```

## 为什么需要它

DSH 的窗口级提示只在你盯着窗口时才看得见。你切到浏览器、让智能体去啃一个长任务，等回来时才发现结果已经躺了十分钟——中途没有任何信号。

`dsh-done-flash` 监听会话事件流，在 `turn/end`（一轮真正结束）时点亮托盘图标：

- 只在 DSH 窗口**不在前台**时闪（可配置）；
- 子智能体的隐藏会话不闪（可配置）；
- 用的就是托盘里你自己的那个图标，不换角标、不弹通知。

## 环境要求

| | |
| --- | --- |
| 操作系统 | Windows 10 / 11 |
| 宿主 | DSH Desktop `>=0.2.0-rc.1 <0.3.0 || >=0.2.2-rc.1 <0.3.0` |
| 运行时 | 系统自带的 Windows PowerShell 5.1（无需下载） |
| Node | 运行时零依赖 |

Linux / macOS 宿主不支持（包内声明 `"os": ["win32"]`）。

## 安装

Web 界面：**设置 → 插件 → 安装**，指向本包；或在终端：

```sh
dsh plugin --profile desktop add github:Samuel-Shao/dsh-done-flash
```

本地目录 / 开发调试：

```sh
dsh plugin --profile desktop add link:F:\path\to\dsh-done-flash
```

安装后插件以 bundle `dsh-done-flash` 出现；若宿主提示 `restart-required`，重启应用即可。

## 配置

全部可选，下面是默认值。

```yaml
- id: dsh-done-flash
  name: dsh-done-flash
  config:
    enabled: true              # 总开关，关掉不必卸载
    onlyWhenBackground: true   # DSH 窗口在前台时不闪
    skipSubagents: true        # 忽略子智能体会话
    untilForeground: true      # 一直闪，直到把 DSH 切回前台
    maxDurationMs: 0           # 该模式的兜底上限；0 = 不设上限
    durationMs: 4000           # untilForeground 关闭时的固定时长
    intervalMs: 460            # 半周期（每个状态停留多久）
    style: blink               # blink | ring | badge | invert
    accent: '#22C55E'          # 任意 #RRGGBB
    appTitle: 'DeepSeek Harness' # 标题含该字样的窗口也算"切回前台"
    iconPath: ''               # 默认取应用自己的 resources/tray.ico
    restoreOnLoad: true        # 崩溃后自动修复残留的高亮图标
    logFile: ''                # 默认 $DSH_HOME/log/dsh-done-flash.log
    testOnLoad: false           # 加载 1.5 秒后先闪一次做自检
```

默认 `untilForeground: true`：闪烁不会自己超时，一旦检测到 DeepSeek Harness 窗口被激活（或切到标题含 `DeepSeek Harness` 的浏览器标签）就立刻停下并复原。想设兜底时长就填 `maxDurationMs`（毫秒，如 `600000`）；想回到固定时长闪烁就设 `untilForeground: false` 并调 `durationMs`。

写在 `~/.dsh/profiles/<profile>/cordis.patch.yml` 顶层，用条目 id 匹配。改配置不需要重装。

### 样式

| 样式 | 效果 |
| --- | --- |
| `blink`（默认） | 图标消失又出现——微信那种闪法，最像"提醒"而不像"报警" |
| `ring` | 整块变成完成色、鲸鱼缩进中间——最显眼，但会改掉托盘图标配色 |
| `badge` | 右下角一个实心圆点，鲸鱼不动 |
| `invert` | 鲸鱼剪影改成完成色 |

只有 `ring`、`badge`、`invert` 用 `accent`（`#22C55E` 绿表示"完成"，也可用 `#F59E0B` 琥珀、`#3B82F6` 蓝）；`blink` 显示的是原图标，`accent` 不参与。

## 工作原理

1. 宿主进程里收到 `session/event`，`type === 'turn/end'`。
2. 插件以隐藏方式启动 `lib/tray-flash.ps1`，把应用的 `resources/tray.ico` 传进去。
3. 助手脚本找到桌面进程的 Electron 托盘消息窗口（`Electron_NotifyIconHostWindow`），用 `Shell_NotifyIconGetRect` 定位鲸鱼的 `uID`，再从 `tray.ico` 里按偏移取出 PNG 帧（应用把 7 个尺寸全存成了 PNG）。
4. 按当前 DPI 选帧、合成高亮帧，用 `Shell_NotifyIcon(NIM_MODIFY)` 在原图与高亮图之间切换 `durationMs`。
5. 结束时一定恢复原图标；加载时也会先恢复一次，防止上次被中断留下高亮。

不碰任何 Electron API：托盘图标归主进程所有，插件走的是系统通知区自己的那套消息，不 patch 任何文件、不往渲染进程注入代码。

## 文件

| 路径 | 作用 |
| --- | --- |
| `lib/index.js` | cordis 插件：事件过滤、合并排队、配置、日志 |
| `lib/tray-flash.ps1` | Win32 助手：定位托盘、取帧、合成、闪烁循环 |
| `test/plugin.test.mjs` | 假 ctx 的无头自测（会真的闪一次） |

## 自测

```sh
node test/plugin.test.mjs
# plugin self-test passed
```

自测会挂一个假 ctx，依次发出 `step/end`（必须忽略）、子会话 `turn/end`（忽略）、真实 `turn/end`（必须闪），并打印助手脚本的 JSON 结果。

## 日志

```json
{"time":"2026-11-11T09:12:34.567Z","kind":"flash","reason":"turn/end","result":{"ok":true,"uid":3,"size":16,"dpi":96,"style":"ring","toggles":16,"failed":0}}
```

`$DSH_HOME/log/dsh-done-flash.log`，一行一个 JSON。

## 排障

**完全不闪。** 先看日志：有 `loaded` 说明插件在跑，有 `flash` 说明触发过。`error: "icon-path-missing"` 表示 `iconPath` 没解析到，手动指定；`uids: []` 表示没找到托盘图标，可能托盘被重建、或 DSH 以更高权限/其他用户运行。

**窗口在前台也闪。** 你的前台窗口不被判定为 DSH 主窗口（例如全屏游戏、提权窗口）。不想管就设 `onlyWhenBackground: false`，或者忽略。

**图标卡在高亮。** `restoreOnLoad` 会在下次启动修复；也可以卸载重装。

**杀软报警。** 助手只调用本系统自带的 `shell32`/`user32` 导出函数。如果策略禁止执行 PowerShell 脚本，插件无法工作——跨进程改别人的托盘图标没有纯 Node 的路子。

## 许可证

MIT。
