<div align="center">

# chain

**A tiny scrolling window manager for macOS.**

Your windows sit side by side on one horizontal strip that runs past the edges of the screen.
Opening a window never shrinks the others. You move around by scrolling.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5%20%7C%206-F05138?style=flat-square&logo=swift&logoColor=white)](main.swift)
[![Memory](https://img.shields.io/badge/idle%20memory-~5.5%20MB-2ea44f?style=flat-square)](#memory)
[![Binary](https://img.shields.io/badge/binary-180%20KB-informational?style=flat-square)](#memory)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)](LICENSE)

[Features](#features) · [Install](#install) · [Shortcuts](#shortcuts) · [Configuration](#configuration) · [How it works](#how-it-works) · [Limitations](#limitations)

</div>

---

## Why

Grid tilers squeeze every window into the screen. Each new window shrinks the rest. Scrolling window managers such as [niri](https://github.com/YaLTeR/niri) and [PaperWM](https://github.com/paperwm/PaperWM) take a different approach. Each window keeps the width you gave it, new windows slot in beside the focused one, and the strip scrolls to show whatever has focus.

`chain` brings that model to macOS in a single Swift file. It has no dependencies and uses very little memory.

## Features

- **Endless strip:** a separate strip for each display. Windows are columns, and the strip scrolls just enough to show the focused one.
- **Spring scrolling:** a critically damped spring that is retargetable mid-flight and never overshoots.
- **Trackpad and mouse:** hold ⌃⌥ and scroll with two fingers to drag the strip, and it settles on the nearest column. Rubber-banding applies at the ends.
- **Width presets:** cycle through ¼, ⅓, ½, ⅔ and ¾, go full width, centre a column, or nudge the width up or down.
- **Stacks and tabs:** put several windows in one column, resize them, or turn the column into tabs.
- **Pinned columns:** pin a window to the left or right edge while the rest of the strip scrolls.
- **Floating:** toggle any window out of the strip, or float whole apps from the config file.
- **Multiple displays:** send a window to the next display. Columns that are out of view never spill onto a neighbouring screen.
- **Background windows:** a window that opens in the background doesn't steal focus or scroll the strip.
- **Stubborn apps:** if an app refuses the width it's given, its column keeps the width the app chose.
- **Scriptable:** every action is also a command (`chain focus-left`), so it works with Raycast, Alfred, BetterTouchTool or skhd.
- **Clean exit:** quitting puts every window back on screen.

## Requirements

- macOS 13 Ventura or later, on Apple silicon or Intel
- Xcode Command Line Tools, to build (`xcode-select --install`)
- Accessibility permission, which every macOS window manager needs to move windows

## Install

```bash
git clone https://github.com/tomtan2007/chain.git
cd chain
./build.sh
./chain
```

On first run, macOS asks for Accessibility access. Enable it in **System Settings → Privacy & Security → Accessibility**. `chain` waits and starts on its own once access is granted.

To install it on your `PATH`:

```bash
sudo cp chain /usr/local/bin/
```

<details>
<summary><b>Start at login</b></summary>

Save this as `~/Library/LaunchAgents/dev.chain.plist`, then run `launchctl load ~/Library/LaunchAgents/dev.chain.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.chain</string>
  <key>ProgramArguments</key><array><string>/usr/local/bin/chain</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
```

`KeepAlive` restarts `chain` if it crashes, but not after you quit it with ⌃⌥Q.

</details>

## Shortcuts

All shortcuts use **⌃⌥** (Control+Option). Plain Option is left alone, so it keeps working for typing and for jumping by word.

| Shortcut | Action |
|---|---|
| ⌃⌥ <kbd>H</kbd> <kbd>L</kbd> or <kbd>←</kbd> <kbd>→</kbd> | Focus left / right |
| ⌃⌥ <kbd>J</kbd> <kbd>K</kbd> or <kbd>↓</kbd> <kbd>↑</kbd> | Focus down / up within a stack |
| ⌃⌥⇧ + any of the above | Move the window instead of focus |
| ⌃⌥⌘ <kbd>←</kbd> <kbd>→</kbd> | Focus the first / last column (add ⇧ to move) |
| ⌃⌥ <kbd>1</kbd>…<kbd>9</kbd> | Jump to column *n*, where 9 is the last (add ⇧ to move there) |
| ⌃⌥ <kbd>R</kbd> | Cycle width presets |
| ⌃⌥ <kbd>F</kbd> | Toggle full width |
| ⌃⌥ <kbd>C</kbd> | Centre the focused column |
| ⌃⌥ <kbd>=</kbd> / <kbd>-</kbd> | Wider / narrower |
| ⌃⌥⇧ <kbd>=</kbd> / <kbd>-</kbd> | Taller / shorter within a stack |
| ⌃⌥ <kbd>0</kbd> | Equalise stack heights |
| ⌃⌥ <kbd>]</kbd> / <kbd>[</kbd> | Stack into the left / right column |
| ⌃⌥⇧ <kbd>]</kbd> / <kbd>[</kbd> | Pop out of the stack to the right / left |
| ⌃⌥⇧ <kbd>T</kbd> | Toggle a tabbed column |
| ⌃⌥ <kbd>T</kbd> | Float / unfloat the window |
| ⌃⌥ <kbd>N</kbd> | Send the window to the next display |
| ⌃⌥ <kbd>P</kbd> / ⌃⌥⇧ <kbd>P</kbd> | Pin to the left / right edge (press again to unpin) |
| ⌃⌥ <kbd>Q</kbd> | Quit |
| ⌃⌥ + two-finger scroll | Drag the strip, which then settles on the nearest column |
| ⌃⌥ + mouse wheel | Move one column per notch |

### Command line

While `chain` is running, `chain <action>` sends an action to it:

```bash
chain focus-left       chain move-right      chain cycle-width     chain full-width
chain center           chain stack-left      chain unstack-right   chain tabbed
chain float            chain pin-left        chain next-display    chain focus-3
chain move-to-1        chain reload          chain quit
```

## Configuration

`chain` reads `~/.config/chain/config` at startup. Every key is optional.

```ini
# Space between windows and at the screen edges, in points
gap = 8

# Width presets, as fractions of the screen, for ⌃⌥R
widths = 0.25, 0.333, 0.5, 0.667, 0.75

# Width of newly opened windows
default_width = 0.5

# Set to false for instant moves
animate = true

# Bundle IDs that always float
float = com.apple.calculator, com.apple.systempreferences
```

Run `chain reload` to apply changes without restarting.

## How it works

```
 ┌──────────── display ────────────┐
 │ ┌──────┐ ┌──────────┐ ┌───────┐ │┌────────┐ ┌─────┐
 │ │  A   │ │    B     │ │   C   │ ││   D    │ │  E  │   ← columns past the edge
 │ │      │ │ (focus)  │ ├───────┤ ││        │ │     │
 │ │      │ │          │ │   C2  │ ││        │ │     │   ← C is a stack
 │ └──────┘ └──────────┘ └───────┘ │└────────┘ └─────┘
 └─────────────────────────────────┘
   ◀──────────── scroll offset ────────────▶
```

- **Model.** Each display has a `Strip` holding an ordered list of `Col`s. Each column has a width fraction and one or more windows with height weights. A column's pixel width is `round(frac × (W − gap) − gap)`.
- **Reveal.** When focus changes, the strip scrolls just enough to show the focused column plus one gap. It doesn't recentre unless you press ⌃⌥C.
- **Animation.** The strip scroll uses an exact-step, critically damped spring (ω = 13), and every window has its own position spring (ω = 15). Moving, stacking and opening windows glide instead of jumping. Frames run at the display's refresh rate (120 Hz on ProMotion), only while something is moving. When idle, `chain` uses no CPU.
- **Input never waits on windows.** The event tap only records where your fingers are. A separate render queue draws the latest position each frame, so trackpad events are never held up by a slow app.
- **Apps can't stall each other.** Each app's windows are moved on that app's own queue. If an app is still busy with the last frame, it skips ahead to the newest position, and every other window keeps moving.
- **Gestures.** Scroll deltas move the strip directly, with rubber-banding past the ends. At lift, the velocity comes from the last 100 ms of movement, so pausing before you lift means no fling. The strip then glides to the nearest column edge. Focus switches only after the glide ends, because activating an app briefly stalls its window. The system's own momentum events are swallowed, so they never scroll the app underneath.
- **Events.** One `CGEventTap` handles both keys and scrolling. `AXObserver`s track window creation, focus, minimising and closing. `NSWorkspace` notifications track app launches, Space changes and wake from sleep.
- **Fewer window moves.** Each window remembers the frame it was last given. Unchanged windows and windows that stay off-screen are skipped. While scrolling, only positions are sent, never sizes.

## Memory

`chain` runs as a bare `CFRunLoop` with no `NSApplication`, no SwiftUI and no windows of its own.

| Measurement (`footprint`) | Value |
|---|---|
| Idle, with `NSApplication` | 7.7 MB |
| **Idle, bare run loop (shipped)** | **5.5 MB** |
| Binary size (`-Osize`, stripped) | 180 KB |

Scrolling, measured by sampling a window's on-screen position during a synthetic ⌃⌥ trackpad drag:

| | Before 1.1 | Now |
|---|---|---|
| Median time between window moves | 12–14 ms | 8.5 ms (120 Hz) |
| 95th-percentile time between moves | 45–63 ms | ~20 ms |
| Stall when lifting the fingers | ~100 ms, with a 150 px jump | none |

## Limitations

- **Three- and four-finger swipes** without a modifier need Apple's private `MultitouchSupport` framework. `chain` uses ⌃⌥ + two-finger scroll instead.
- **No on-screen chrome:** there's no strip indicator, focus border or settings window. Each would need windows of its own, which goes against the memory budget.
- **Spaces:** windows on other Spaces are skipped, but each display keeps one column order and one scroll position across all its Spaces.
- **Layout isn't saved** between restarts.
- **Keys are physical key positions**, so AZERTY, QWERTZ and Dvorak users get the US-layout positions.
- **Window IDs** come from `_AXUIElementGetWindow`. It's a private but long-stable symbol that every macOS tiling window manager relies on.

## Contributing

Issues and pull requests are welcome. The whole program is [`main.swift`](main.swift), grouped into `// MARK:` sections: config, spring, AX helpers, model, displays, tracking, animation, actions and the event tap. Please keep it to one file with no dependencies, and check the idle `footprint` before and after your change.

```bash
./build.sh && ./chain     # build and run
footprint $(pgrep -x chain)  # check memory
```

## Acknowledgements

Inspired by [niri](https://github.com/YaLTeR/niri), [PaperWM](https://github.com/paperwm/PaperWM) and [ChainYourMac](https://chainyourmac.com). `chain` is an independent project. It is not affiliated with or endorsed by any of them, and it contains none of their code.

## License

[MIT](LICENSE) © 2026 Tom Tan
