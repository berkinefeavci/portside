# Privacy

Portside has no analytics, crash reporting or update checks of its own; "Check for Updates" only opens the releases page in your browser.

**Site previews** are the one exception to "nothing leaves your Mac": to take a picture of a running server's page, Portside opens `http://localhost:<port>` in a hidden web view for a few seconds, then empties it. The page behaves as it would in a browser tab, so any fonts, scripts or analytics it loads from the internet are loaded then too. The web view only opens `http(s)://localhost`, `127.0.0.1` or `[::1]` and cancels navigation anywhere else, opens no new windows, allows no downloads, camera or microphone, and keeps no cookies or other site data between pictures. Turn **Site previews** off in Settings to stop this; doing so also deletes the saved pictures.

## Stored on your Mac

- `~/Library/Application Support/Portside/history.json`: for each dev server Portside has seen, the project folder and name, port, framework, the program and arguments that started it (**as they were typed**, so don't pass secrets as command-line arguments), its environment variables (minus anything that looks like a secret, see below), your custom command if you set one, and when it was first and last seen. Permissions `0600` (the folder is `0700`). Up to 200 entries; pinned ones are kept.
- `~/Library/Application Support/Portside/history.corrupt-<date>.json`: only if `history.json` couldn't be read. Portside moves it aside instead of overwriting it, and keeps the three newest. It is your old history, so it may still hold what older versions saved; delete it when you don't need it.
- `~/Library/Application Support/Portside/Previews/*.jpg`: the last picture of each server's page (about 50 KB each). Permissions `0600`. Removed when the entry is removed from history, cleared, or ages out of the 200.
- `~/Library/Logs/Portside/*.log`: the output of servers Portside started, which can contain whatever the server prints. Permissions `0600`. Each file is overwritten the next time that server starts, cut back to its last lines if it grows past 8 MB while running, and removed when its history entry is.
- `UserDefaults` (`io.github.berkinefeavci.portside`): your settings and the list of hidden project folders.

## Not stored

Environment variables are filtered before they are saved, and again when an older history file is read (which is then rewritten without them):

- by **name**: containing `SECRET`, `TOKEN`, `PASSWORD`, `PASSWD`, `PASSPHRASE`, `CREDENTIAL`, `PRIVATE`, `COOKIE`, `SESSION`, `AUTH`, `APIKEY`, `ACCESSKEY`, `DATABASE_URL`, `CONNECTION_STRING`, `JWT`, `BEARER` or `IDENTITY`, or having `KEY`, `KEYS`, `PASS`, `PWD`, `DSN`, `PAT` or `SALT` as a word (`AWS_ACCESS_KEY_ID`, `dbPass`), in any case;
- by **value**, whatever the name: a URL with a password (`postgres://user:secret@host/db`), a private key, a JWT, or a well-known token format (`sk-…`, `ghp_…`, `xoxb-…`, `AKIA…`, …);
- session-bound values such as `SSH_AUTH_SOCK`, `SSH_CONNECTION` and `TERM_SESSION_ID`, and variables of the terminal, editor or coding agent that started the server (`TERM_PROGRAM*`, `ITERM_*`, `VSCODE_*`, `TMUX*`, `CLAUDE*`, `CODEX_*`, …), which don't belong to the server.

Everything else (`PATH`, `PORT`, `NODE_ENV`, toolchain settings) is kept because a server may not start without it. Command-line arguments are not filtered.

## Permissions

- **Accessibility** (optional): used to bring the right Simulator window to the front when you click a simulator. Portside reads the window titles of Simulator.app for that and nothing else.
- **Files and folders** (Desktop, Documents, Downloads): macOS asks the first time Portside reads or starts something there.
- **Login Items** (optional): *Open at login*, approved in System Settings if macOS asks.

## Removing everything

Quit Portside, then delete the app and these locations:

```bash
rm -rf ~/Library/Application\ Support/Portside ~/Library/Logs/Portside   # history, previews, logs
defaults delete io.github.berkinefeavci.portside
```
