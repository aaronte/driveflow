# Security

If you find a vulnerability, please open a private GitHub advisory (or email the maintainer) before filing a public issue.

Sign-in tokens live at `~/Library/Application Support/Driveflow/session.tokens` (mode `0600`), with a best-effort Keychain mirror. The download engine uses an app-private rclone config at `~/Library/Application Support/Driveflow/rclone.conf` — not `~/.config/rclone/rclone.conf`. Queue state and `rclone.log` in that folder are also `0600`.

Sign out clears those stores and stops the engine. Treat the Application Support folder as sensitive on a shared Mac.
