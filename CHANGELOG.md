# Changelog

## Unreleased

- Go and Rust programs you compiled yourself (`go build -o bin/api`, air's `tmp/main`, a release binary in `dist/`) are listed too, when they run from a folder with a `go.mod` or `Cargo.toml` and live inside it.
- A failed restart stays on its card, with the reason, until you dismiss it, and can be retried from there.
- Go and Cargo servers (`go run`, `cargo run`) are found and restarted with `go run` / `cargo run`.
- Scanning can no longer freeze on a command with a lot of output or one that hangs, and a scan that fails keeps what is shown instead of reporting every server as stopped.
- Scanning is lighter: ports every 3 s while the panel is open and every 10 s otherwise, no `lsof`/`ps` per server per scan, and `simctl` only while a simulator can be running (plus a check every five minutes).
- Site previews: turning them off stops pending captures at once; a failed capture is retried after 15 s instead of minutes; the hidden web view loads only localhost and cancels navigation elsewhere.
- "Copy the full output" copies the whole log, and a button opens it.
- Keyboard shortcuts another app already uses, Simulator focus without the Accessibility permission, and Open at login waiting for approval are now shown in Settings or on the row instead of failing silently. Simulator windows are matched by their full name.
- History: an unreadable history file is moved aside (`history.corrupt-<date>.json`) instead of being erased by the next save; write errors are shown.
- Removing, clearing or aging out a history entry now deletes its page picture and output log.
- Secrets: variables with secret-looking names (now including `KEY`, `PASS`, `DATABASE_URL`, …) or values (URLs with passwords, private keys, tokens), and variables of the terminal, editor or agent session that started the server, are never saved, and old history files are cleaned when read. History, logs and pictures are private (`0600`/`0700`); logs are capped at 8 MB while running.
- Edit Command no longer fills in a process title such as `next-server (v14)` as if it were a command.
- "1 server" in Clear History; Next.js is only detected by program name, not any path containing "next".
- `release.sh` writes a `.sha256` that `shasum -c` accepts next to the DMG.

## 1.0.0 — 2026-10-09

First public release.

- Running dev servers as cards with a preview of each page; open, restart or stop them.
- Closed servers keep the last picture of their page, in colour; a server started again with other arguments keeps its project's picture.
- Menu bar icon: a small window with the number of running servers that rolls, counts on hover and shows a loading bar while a server starts.
- Liquid Glass panel on macOS 26 and later.
- Recently Closed and a searchable, day-grouped History: reopen any server Portside has seen with its original command, folder and environment.
- Reopen the last closed server (↩ button, optional ⌃⌥⌘T shortcut); toggle the panel with ⌃⌥⌘P.
- Pin servers, hide projects, remove entries, clear history.
- Edit Command…: start a server with your own command through your login shell.
- Servers started by Portside log to `~/Library/Logs/Portside/` and keep running when Portside quits.
- Failure output shown in place, with copy and the full log.
- iOS Simulator monitoring (relaunch app, shut down).
- English and Turkish.
- Universal binary (Apple Silicon and Intel), macOS 14 or later.
