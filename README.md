# FlowX

[中文](README_zh.md)

A minimalist macOS menu bar lyrics viewer for **Apple Music**, featuring real-time karaoke-style synced lyrics with zero CPU rendering.

<p>
  <img src="assets/karaoke-en-light.gif" height="40" />
</p>

## Features

- **Real-time synced lyrics** — TTML lyrics displayed directly in the menu bar, perfectly synced with playback
- **Karaoke effect** — word-by-word highlight animation (can be toggled off for plain scrolling)
- **Hover playback controls** — previous / play·pause / next buttons appear on hover
- **Smart interlude detection** — displays animated ♪ notes during intros and instrumental breaks
- **Edge fade** — configurable gradient fade on lyrics edges for a polished look
- **Adjustable width** — lyrics area width from 120 pt to 320 pt
- **TTML lyrics from Apple Music API** — with local disk caching
- **Auto dark/light mode** — adapts to system appearance seamlessly
- **10 languages** — English, 简体中文, 繁體中文, Deutsch, Español, Français, 日本語, 한국어, Português (Brasil), Русский

## Requirements

- macOS 26.0+
- Apple Music

## Installation

Download the latest `FlowX-vX.X.X.zip` from [Releases](https://github.com/kadxy/FlowX/releases), unzip, and drag `FlowX.app` to `/Applications`.

> Since the app is not notarized, on first launch right-click → **Open**, then confirm in the dialog.

## Configuration

Open **Settings** (⌘,) from the FlowX menu bar icon.

| Section | Option | Description |
| --- | --- | --- |
| Apple Music API | User Token | Paste your `media-user-token` from Apple Music web player (browser DevTools) |
| Apple Music API | Storefront | Select your Apple Music region (auto-detected from system locale) |
| Menu Bar Lyrics | Lyrics Width | Adjust the lyrics display width (120–320 pt) |
| Menu Bar Lyrics | Edge Fade | Gradient fade width on both edges (0–60 pt) |
| Menu Bar Lyrics | Karaoke Effect | Toggle word-by-word highlight on/off |
| General | Language | UI language (follows system by default) |

## Tech Stack

- Swift / SwiftUI + AppKit
- ScriptingBridge — Apple Music playback control
- Apple Music API — TTML lyrics fetching
- CALayer + CAAnimation — zero-CPU menu bar rendering
- MediaRemote.framework (via osascript) — catalog song ID retrieval

## Building from Source

```bash
git clone https://github.com/kadxy/FlowX.git
cd FlowX
open FlowX.xcodeproj
```

Build and run with Xcode 16+ (macOS 14.0 deployment target). Sandbox must be disabled.

## License

[GPL-3.0](LICENSE)
