# Privacy

Portside does not connect to the internet. It has no analytics, crash reporting or update checks; "Check for Updates" only opens the releases page in your browser.

## Stored on your Mac

- `~/Library/Application Support/Portside/history.json`: for each dev server Portside has seen, the project folder and name, port, framework, the program and arguments that started it, its environment variables (minus anything that looks like a secret), your custom command if you set one, and when it was first and last seen. Permissions `0600`. Up to 200 entries; pinned ones are kept.
- `~/Library/Logs/Portside/*.log`: the output of servers Portside started. Each file is overwritten the next time that server starts.
- `UserDefaults` (`io.github.berkinefeavci.portside`): your settings and the list of hidden project folders.

## Not stored

Environment variables whose name contains `SECRET`, `TOKEN`, `PASSWORD`, `PASSWD`, `API_KEY`/`APIKEY`, `PRIVATE`, `CREDENTIAL`, `AUTH`, `COOKIE` or `SESSION`, and session-bound values such as `SSH_AUTH_SOCK` and `TERM_SESSION_ID`.

## Removing everything

Quit Portside, then delete the app and these locations:

```bash
rm -rf ~/Library/Application\ Support/Portside ~/Library/Logs/Portside
defaults delete io.github.berkinefeavci.portside
```
