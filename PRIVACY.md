# Privacy

Portside has no analytics, crash reporting or update checks of its own; "Check for Updates" only opens the releases page in your browser.

**Site previews** are the one exception to "nothing leaves your Mac": to take a picture of a running server's page, Portside opens `http://localhost:<port>` in a hidden web view for a few seconds, then empties it. The page behaves as it would in a browser tab, so any fonts, scripts or analytics it loads from the internet are loaded then too. Turn **Site previews** off in Settings to stop this; doing so also deletes the saved pictures.

## Stored on your Mac

- `~/Library/Application Support/Portside/history.json`: for each dev server Portside has seen, the project folder and name, port, framework, the program and arguments that started it, its environment variables (minus anything that looks like a secret), your custom command if you set one, and when it was first and last seen. Permissions `0600`. Up to 200 entries; pinned ones are kept.
- `~/Library/Application Support/Portside/Previews/*.jpg`: the last picture of each server's page (about 50 KB each), removed when the entry is removed from history.
- `~/Library/Logs/Portside/*.log`: the output of servers Portside started. Each file is overwritten the next time that server starts.
- `UserDefaults` (`io.github.berkinefeavci.portside`): your settings and the list of hidden project folders.

## Not stored

Environment variables whose name contains `SECRET`, `TOKEN`, `PASSWORD`, `PASSWD`, `API_KEY`/`APIKEY`, `PRIVATE`, `CREDENTIAL`, `AUTH`, `COOKIE` or `SESSION`, and session-bound values such as `SSH_AUTH_SOCK` and `TERM_SESSION_ID`.

## Removing everything

Quit Portside, then delete the app and these locations:

```bash
rm -rf ~/Library/Application\ Support/Portside ~/Library/Logs/Portside   # history, previews, logs
defaults delete io.github.berkinefeavci.portside
```
