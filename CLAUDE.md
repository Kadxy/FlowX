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
- Menu bar rendering: pre-render text to CGImage + CALayer/CAAnimation (zero CPU)
