# App image provenance

The five numbered PNGs were captured from the debug build of Codex Remote on
macOS 26.6.2 on 2026-09-28. `CODEX_REMOTE_SCREENSHOT_MODE` supplies local,
illustrative provider and machine state through `ScreenshotFixtures.swift`;
the windows are the app's real SwiftUI views. No provider credentials, machines,
or network requests were used. The captures retain the native window chrome;
the New machine and Providers windows were activated before capture so their
controls show their normal enabled appearance.

`app-icon.png` is the 512-pixel export from `Scripts/make-icon.swift`. The same
generator builds `CodexRemote.icns`, which `Scripts/bundle.sh` installs in the
app bundle for distribution.
