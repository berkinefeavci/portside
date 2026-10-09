# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Use GitHub's private vulnerability reporting instead: this repository's **Security** tab → **Report a vulnerability**.

Include your macOS version, Portside version (Settings → About Portside) and steps to reproduce.

## What Portside can do on your Mac

Portside is not sandboxed, because it has to see other processes and start servers in your project folders. It runs with your user's permissions only: no privileged helper, no root, no network listener and no network requests.

- It **reads** process information (`lsof`, `ps`, `sysctl KERN_PROCARGS2`) for processes listening on TCP ports.
- It **starts** programs you have already run yourself, in the same folder, with the arguments and environment they had, or the command you typed in **Edit Command…**.
- It **stops** processes you ask it to stop (SIGTERM, then SIGKILL after 1.5 s), including their child processes.
- The history file contains commands and environment variables, so it is written with `0600` permissions. Variables that look like secrets are filtered out before saving.

Anyone who can write to your `history.json` can make Portside run a command the next time you click that entry, but they can already run commands as you. Reports showing a way around this are welcome.
