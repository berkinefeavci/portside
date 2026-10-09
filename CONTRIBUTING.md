# Contributing

Thanks for helping. Portside is small on purpose, so a short discussion in an issue before a large change saves everyone time.

## Development

```bash
./check.sh             # unit tests, universal build, localization check (what CI runs)
./build.sh --install   # build and run the app from /Applications
```

Headless checks that don't need clicking through the menu bar:

```bash
PORTSIDE_SNAPSHOT=/tmp/panel.png dist/Portside.app/Contents/MacOS/Portside          # render the panel
PORTSIDE_REOPEN="My Project" dist/Portside.app/Contents/MacOS/Portside              # reopen a history entry
```

See `Sources/Portside/App/SelfTest.swift` for all switches.

## Guidelines

- Keep it local: no network requests, no analytics, no new dependencies without a good reason.
- Every user-facing string goes through `Text("…")`, `LocalizedStringKey` or `String(localized:)`, with a translation in `Localization/tr.lproj/Localizable.strings`. `./build.sh` fails when a translation is missing.
- Never block the main thread on file access: files inside Desktop, Documents or Downloads can wait on a macOS privacy prompt.
- Add a test in `Tests/PortsideTests` for logic that doesn't need a running server.
- Match the surrounding code style. Comments explain *why*, not *what*.

## Adding a language

Copy `Localization/tr.lproj` to `<code>.lproj`, translate the values (keep the `%@`/`%lld` specifiers), add the code to `CFBundleLocalizations` in `Packaging/Info.plist`, and run `./build.sh`.
