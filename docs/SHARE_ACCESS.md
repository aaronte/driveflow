# Share-access Drive browse

Driveflow no longer browses with the user’s `drive.readonly` OAuth token. The Mac app:

1. Signs the **buyer** in with Google (`openid email`) for license checks.
2. Obtains a **short-lived access token** for a Google Cloud **service account**.
3. Shows that SA’s email so the user can share a folder as Viewer (Notify off).
4. Lists `sharedWithMe = true and trashed = false` with that token, then reuses `BrowserView` / `DriveBrowserModel` / `DriveClient`.
5. Configures rclone with the **same** SA access token for downloads.

## What to create in GCP (`driveflow-503421`)

1. Enable **Google Drive API**.
2. Create a **service account** (IAM → Service accounts). Example email:
   `lic-xxxxx@driveflow-503421.iam.gserviceaccount.com`.
3. For local/dev only: create a JSON key and store it on the Mac under
   `~/Library/Application Support/Driveflow/service-account.json` (mode `600`)
   or point `DRIVEFLOW_SA_KEY_PATH` at it.
4. Do **not** enable domain-wide delegation for this flow.
5. Do **not** put the JSON key in the app bundle, git, or rclone config.

When a user shares a folder with the SA as Viewer (Notify unchecked), the item
appears under the SA’s Shared with me. Shared Drives require adding the SA as a
**member** of the shared drive. Google Workspace tenants may block sharing with
external addresses — that’s an admin setting, not an app bug.

## Token model

| Identity | Scope / credential | Used for |
| --- | --- | --- |
| Buyer Google account | `openid email` (Desktop OAuth + PKCE) | License check (`POST {email}`), UI “signed in as” |
| Service account | `drive.readonly` via 2LO JWT or mint API | Drive list + rclone download |

The Mac app may hold:

- Public **share email** (display / copy)
- Short-lived **access token** + expiry in the existing credential store

It must never ship or persist the SA private key in production builds.

### Mint resolution order

1. **`DRIVEFLOW_SHARE_MINT_URL`** — `POST {"email":"<buyer>"}` → JSON below.
2. **Extended license check** — same fields on `DRIVEFLOW_LICENSE_CHECK_URL` when `allowed: true`.
3. **Local SA JSON** — Application Support / `DRIVEFLOW_SA_KEY_PATH` (dev).
4. **Env token** — `DRIVEFLOW_SHARE_EMAIL` + `DRIVEFLOW_SHARE_ACCESS_TOKEN` (+ optional `DRIVEFLOW_SHARE_TOKEN_EXPIRES_IN`).

### Mint API contract

```http
POST /api/drive/session
Content-Type: application/json

{"email":"buyer@example.com"}
```

```json
{
  "shareEmail": "lic-xxxxx@driveflow-503421.iam.gserviceaccount.com",
  "accessToken": "ya29....",
  "expiresIn": 3600
}
```

`expiresAt` (unix seconds) is also accepted instead of `expiresIn`.

License check may return the same share fields alongside `allowed`:

```json
{
  "allowed": true,
  "shareEmail": "lic-xxxxx@driveflow-503421.iam.gserviceaccount.com",
  "accessToken": "ya29....",
  "expiresIn": 3600
}
```

License email is always the **buyer** Google email — never the share-target inbox.

## Isolation

Ideal: **one SA per license** (backend provisions SA emails). GCP projects typically
allow on the order of **~100 service accounts**, so high volume needs a provisioning
strategy or a different isolation design.

This first version supports **one shared SA** plus **bound folder IDs per buyer email**
(`BoundFolderStore` under Application Support). Shared-with-me roots are filtered to
IDs bound when the user completed share onboarding. Caveats:

- A stolen shared SA token/key can see every folder ever shared with that SA.
- Search only weakly filters by bound IDs / parents; prefer one SA per license for strong isolation.

## Local test plan

1. Create/use one SA; place its JSON key in Application Support (gitignored).
2. Configure Desktop OAuth client for sign-in.
3. Run the app → Sign in with Google → copy share email.
4. In Drive, share a test folder as Viewer, **Notify people** unchecked.
5. App should detect the share and open Shared with me; drill into the folder.
6. Download via rclone; confirm transfer works (same SA token).

Helper: `./scripts/mint-sa-token.py --print-exports`.

## Out of scope

- Google Picker / `drive.file` user OAuth browse path
- Domain-wide delegation
- Plus-addressing / mailbox aliases as the share target
