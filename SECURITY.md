# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Use GitHub's private vulnerability reporting instead: this repository's **Security** tab → **Report a vulnerability**.

Include your macOS version, Portside version (Settings → About Portside) and steps to reproduce.

## What Portside can do on your Mac

Portside is not sandboxed, because it has to see other processes and start servers in your project folders. It runs with your user's permissions only: no privileged helper, no root and no network listener. Its only network traffic is loading your own `localhost` pages for site previews (see PRIVACY.md).

- It **reads** process information (`lsof`, `ps`, `sysctl KERN_PROCARGS2`) for processes listening on TCP ports.
- It **starts** programs you have already run yourself, in the same folder, with the arguments and environment they had, or the command you typed in **Edit Command…**. Only when you click, press the shortcut or choose a menu item: never on launch, on reading the history, or on hover. Programs get their arguments as a list, not through a shell; a custom command runs through a shell listed in `/etc/shells` (zsh otherwise). Portside checks that the project folder is a folder before starting anything in it.
- It **stops** processes you ask it to stop (SIGTERM, then SIGKILL after 1.5 s), including their child processes.
- The history file contains commands and environment variables, so it is written with `0600` permissions (folders `0700`). Variables that look like secrets are filtered out by name and by value before saving, and old files are cleaned when read. Server logs and page pictures are `0600` too, size-limited, and deleted with their history entry (details in PRIVACY.md).
- The page preview web view loads only `localhost`, `127.0.0.1` and `[::1]`, keeps no site data and has no script bridge to Portside.
- The optional Accessibility permission is used to raise a Simulator window and for nothing else. Portside has no entitlements: it is not sandboxed, and the Hardened Runtime is on without exceptions.

Anyone who can write to your `history.json` can make Portside run a command the next time you click that entry, but they can already run commands as you. Reports showing a way around this are welcome.
