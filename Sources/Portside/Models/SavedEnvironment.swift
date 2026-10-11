import Foundation

/// Which environment variables of a server are kept in the history file so it can be started again.
///
/// A dev server's environment often holds secrets (API keys, tokens, database URLs). They are
/// left out by name and by what the value looks like, and so are variables of the terminal,
/// editor or agent session that started the server; everything else (PATH, PORT, NODE_ENV,
/// toolchain settings, your own variables) stays, because the server may not start without it.
enum SavedEnvironment {
    /// Names that contain one of these, in any case.
    private static let secretFragments = [
        "SECRET", "TOKEN", "PASSWORD", "PASSWD", "PASSPHRASE", "CREDENTIAL", "PRIVATE", "COOKIE",
        "SESSION", "AUTH", "APIKEY", "ACCESSKEY", "DATABASE_URL", "CONNECTION_STRING", "JWT", "BEARER", "IDENTITY",
    ]
    /// Names with one of these as a whole word (`AWS_ACCESS_KEY_ID`, `dbPass`), so `MONKEY` stays.
    private static let secretWords: Set<String> = ["KEY", "KEYS", "PASS", "PWD", "DSN", "PAT", "SALT"]

    /// Session-bound values that would be stale on the next start anyway.
    private static let staleNames: Set<String> = [
        "_", "PWD", "OLDPWD", "SHLVL", "TERM_SESSION_ID", "ITERM_SESSION_ID", "SECURITYSESSIONID",
        "SSH_AUTH_SOCK", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "LaunchInstanceID",
    ]

    /// Belong to the terminal, editor or coding agent that started the server, not to the server:
    /// restoring them would be wrong (a server restarted from Portside is not inside that session).
    private static let sessionPrefixes = [
        "__CF", "XPC_", "TERM_PROGRAM", "ITERM_", "LC_TERMINAL", "WARP_", "KITTY_", "WEZTERM_", "GHOSTTY_",
        "ALACRITTY_", "VSCODE_", "ELECTRON_", "TMUX", "CLAUDE", "CODEX_", "MCP_",
    ]
    private static let sessionNames: Set<String> = [
        "COLORTERM", "WINDOWID", "STY", "GIT_ASKPASS", "BAGGAGE", "AI_AGENT", "OSLogRateLimit", "MallocNanoZone",
    ]

    /// URLs with a password in them, private keys, JWTs and the well-known token prefixes.
    private static let secretValuePattern = [
        #"^[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]*:[^/\s@]+@"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY"#,
        #"^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*$"#,
        #"^(sk-[A-Za-z0-9_-]{16,}|[rs]k_(live|test)_|gh[pousr]_|github_pat_|glpat-|xox[abposr]-|AKIA[0-9A-Z]{12}|ASIA[0-9A-Z]{12}|AIza[0-9A-Za-z_-]{20}|npm_[A-Za-z0-9]{20}|SG\.[A-Za-z0-9_-]{16})"#,
    ].joined(separator: "|")

    static func filtered(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, value in keeps(name: name, value: value) }
    }

    static func keeps(name: String, value: String) -> Bool {
        guard !name.isEmpty, !name.contains("="), !name.contains("\0"), !value.contains("\0") else { return false }
        guard !staleNames.contains(name), !sessionNames.contains(name),
              !sessionPrefixes.contains(where: name.hasPrefix) else { return false }
        return !hasSecretName(name) && value.range(of: secretValuePattern, options: .regularExpression) == nil
    }

    static func hasSecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        if secretFragments.contains(where: upper.contains) { return true }
        // dbPass → DB_PASS, so camelCase names split into words too.
        let spaced = name.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1_$2", options: .regularExpression)
        let words = spaced.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains(where: secretWords.contains)
    }
}
