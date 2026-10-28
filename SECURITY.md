# Security

If you find a vulnerability, please open a private GitHub advisory (or email the maintainer) before filing a public issue.

Sign-in tokens, including the Google ID token sent to the share-mint server, and short-lived Drive service-account access tokens live in the login Keychain (service `com.aaronte.driveflow`). The app does not copy them into UserDefaults or `session.tokens`.

If `~/Library/Application Support/Driveflow/session.tokens` still exists from an older build, the first credential read or write copies those values into the Keychain and deletes the file. Sign-out removes each account from that file before deleting the Keychain item, so a failed copy cannot sign the buyer back in.

Folder IDs the buyer pasted, and that the service account can read, are stored per buyer email under Application Support. They are not tokens. The file name is a percent-encoding of the email so two different emails cannot share one file.

The download engine does not write the Drive access token into `rclone.conf`. Each transfer sends the token in the request to the local rclone process. The token is one quoted connection-string value. The rclone command line does not include it. If rclone echoes that remote in an error, the saved job text redacts `access_token` and `ya29.` values. Sign-out deletes a leftover `~/Library/Application Support/Driveflow/rclone.conf` from older builds, and deletes the empty temporary config directory created for that process. Queue state and `rclone.log` in Application Support are mode `0600`.

The Mac app does not load a service-account JSON key. It mints Drive access only by calling the share-mint server. Do not commit a service-account key or ship one inside the app.

Sign out clears the Keychain items and stops the engine.
