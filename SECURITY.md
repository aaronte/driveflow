# Security

If you find a vulnerability, please open a private GitHub advisory (or email the maintainer) before filing a public issue.

Sign-in tokens, including the Google ID token sent to the share-mint server, and short-lived Drive service-account access tokens live in the login Keychain (service `com.aaronte.driveflow`). The app does not copy them into UserDefaults or `session.tokens`.

If `~/Library/Application Support/Driveflow/session.tokens` still exists from an older build, the first credential read or write copies those values into the Keychain and deletes the file.

Folder IDs the buyer pasted, and that the service account can read, are stored per buyer email under Application Support. They are not tokens.

The download engine does not write the Drive access token into `rclone.conf`. Each transfer sends the token only in the request to the local rclone process. Sign-out deletes a leftover `~/Library/Application Support/Driveflow/rclone.conf` from older builds, and deletes the empty temporary config directory created for that process. Queue state and `rclone.log` in Application Support are mode `0600`.

The Mac app does not load a service-account JSON key. It mints Drive access only by calling the share-mint server. Do not commit a service-account key or ship one inside the app.

Sign out clears the Keychain items and stops the engine.
