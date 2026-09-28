# App image provenance

The five numbered PNGs were captured from the debug build of Codex Remote on
macOS 26.6.2 on 2026-09-28. `CODEX_REMOTE_SCREENSHOT_MODE` supplies local,
illustrative provider and machine state through `ScreenshotFixtures.swift`;
the windows are the app's real SwiftUI views. No provider credentials, machines,
or network requests were used. The panel, expanded, and first-run captures show
the native title bar and toolbar. The New machine capture was cropped at the
title bar; the Providers window retains its native title bar and toolbar.

`app-icon.png` is the 512-pixel export from `Scripts/make-icon.swift`. The same
generator builds `CodexRemote.icns`, which `Scripts/bundle.sh` installs in the
app bundle for distribution.
