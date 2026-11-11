# CLAUDE.md

- Always respond in Simplified Chinese regardless of input language.
- Always follow Apple's Human Interface Guidelines and best practices.
- Refactoring must not alter functionality, reduce readability, or violate best practices.
- Don't spend energy on internationalization when working on features.

## Project Overview

FlowX — macOS 14.0+ menu bar lyrics viewer & controller for Apple Music.
SwiftUI + AppKit (`NSStatusItem`), ScriptingBridge for Music control, sandbox disabled.

## Key Technical Decisions

- Adam ID (catalog song ID) obtained via osascript + MediaRemote private framework, bypassing macOS 15.4+ entitlement restrictions
- TTML lyrics fetched from `amp-api.music.apple.com`, cached at `~/Library/Caches/FlowX/lyrics/{catalogId}.ttml`
- Settings persisted as JSON at `~/Library/Application Support/FlowX/settings.json`
- Developer token auto-refreshed from Apple Music web JS bundle
- Menu bar rendering: text pre-rendered to CGImage layers; `LyricsAnimationLayer` interpolates its own keyframes on `tick()`, driven by a 60 Hz timer in `MenuBarLyricsView` that runs only while something moves (playing, lyrics visible, not hovering)
- One `NSStatusItem` holds everything. `MenuBarLyricsView` claims all clicks and resolves them from `NSEvent.mouseLocation`, because macOS 27 reports every status item click at the item's centre. Right-click opens the menu; with lyrics off the item shrinks to the logo
- Play/pause updates the state optimistically; Music's `playerInfo` notification remains the source of truth
- Settings window: preference-style `NSToolbar` over SwiftUI panes laid out in a label/control grid, like Apple Music's settings

## Release

- Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the DMG with `MACOSX_DEPLOYMENT_TARGET=14.0` and publishes the GitHub release. Bump `MARKETING_VERSION` to match the tag first: the About window's update check compares against it
- `main` shares no history with `dev` and the feature branches, so work reaches it by cherry-pick, not merge
