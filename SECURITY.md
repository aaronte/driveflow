# Security

If you find a vulnerability, please open a private GitHub advisory (or email the maintainer) before filing a public issue.

Sign-in tokens (including the Google ID token sent to the share-mint server)
and short-lived Drive service-account access tokens live at
`~/Library/Application Support/Driveflow/session.tokens` (mode `0600`), with a
best-effort Keychain mirror. Folder IDs the buyer pasted — and that the service
account can read — are stored per buyer email in the same folder. The download
engine uses an app-private rclone
config at `~/Library/Application Support/Driveflow/rclone.conf` — not
`~/.config/rclone/rclone.conf`. Queue state and `rclone.log` in that folder are
also `0600`.

**Never** commit Google service-account JSON keys or ship them inside the Mac
app. Local/dev keys belong only under Application Support (or
`DRIVEFLOW_SA_KEY_PATH`). Production should mint short-lived SA access tokens
from a backend (see [docs/SHARE_ACCESS.md](docs/SHARE_ACCESS.md)).

Sign out clears session tokens and stops the engine. Treat the Application
Support folder as sensitive on a shared Mac.
