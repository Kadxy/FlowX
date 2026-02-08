# CLAUDE.md

## User Requirements

- Regardless of the language in which the question is asked or the context is provided, ALWAYS answer in Simplified Chinese.
- Always follow Apple’s Human Interface Guidelines and best practices

## Project Overview

**Name:** FlowX (formerly NotchX)
**Type:** macOS Menu Bar Application (LSUIElement, no Dock icon)
**Goal:** A minimalist, native macOS menu bar lyrics viewer and controller exclusively for **Apple Music**.

## Architecture

```text
FlowX/
├── Bridge/            # ScriptingBridge (Music.h, generated from Music.app sdef)
├── Models/            # TrackInfo, LyricLine, PlayerState
├── Services/
│   ├── MusicController.swift    # Singleton, polls Apple Music via ScriptingBridge
│   ├── LyricsService.swift        # Catalog search → TTML fetch → disk cache
│   └── TTMLParser.swift         # TTML XML → [LyricLine]
└── Views/
    ├── MenuBarLyricsView.swift # Scrolling lyrics/track info in menu bar
    └── SettingsWindow.swift     # Status bar width config
```

## Key Technical Decisions

- **ScriptingBridge** controls Apple Music; `persistentID` (local hex ID) used as cache key
- **No catalog songId from ScriptingBridge** — must search Apple Music API to resolve
- **Search strategy:** Library search first (`/v1/me/library/search`), fallback to catalog search
- **TTML cache:** `~/Library/Caches/FlowX/lyrics/{persistentID}-{catalogSongId}.ttml`
- **Tokens** loaded from `.env` file (gitignored): `DEVELOPER_TOKEN`, `USER_TOKEN`, `STOREFRONT`
- **Sandbox disabled** — required for ScriptingBridge to work

## Tech Stack

- **Platform:** macOS 14.0+
- **Language:** Swift 5
- **UI:** SwiftUI + AppKit (`NSStatusItem`, `MenuBarLyricsView` as NSView)
- **Music Integration:** ScriptingBridge + Apple Music private API (`amp-api.music.apple.com`)
- **Networking:** URLSession (async/await)
