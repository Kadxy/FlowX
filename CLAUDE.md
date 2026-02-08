# CLAUDE.md

## User Requirements

- Regardless of the language in which the question is asked or the context is provided, ALWAYS answer in Simplified Chinese.

## Project Overview

**Name:** NotchX (MVP Phase)
**Type:** macOS Menu Bar Application
**Goal:** A minimalist, native macOS controller exclusively for **Apple Music**.
**Key Features:**

1. **Playback Control:** Play/Pause, Next, Previous.
2. **Library Action:** Like (Love) / Dislike (Unlove) current track.
3. **Lyrics:** Fetch **synced lyrics** from **LRCLIB API**.
4. **UI:** Simple Menu Bar dropdown (or floating window) displaying current track and scrolling lyrics.
5. **Config:** Zero configuration. No user settings for the MVP.

## Tech Stack

- **Platform:** macOS (Target: macOS 14.0+)
- **Language:** Swift
- **UI Framework:** SwiftUI
- **System Integration:** * `ScriptingBridge` (to control Apple Music).
  - `AppKit` (for window management/mouse tracking).
  - `MenuBarExtra` (for status bar entry).
- **Networking:** `URLSession` (Native async/await).