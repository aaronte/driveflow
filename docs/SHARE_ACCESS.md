# Share-access Drive browse

Driveflow no longer browses with the user’s `drive.readonly` OAuth token. The Mac app:

1. Signs the **buyer** in with Google (`openid email`) for license checks. The token response includes an OpenID Connect **ID token**.
2. Obtains a **short-lived access token** for a Google Cloud **service account** by sending that ID token to the mint endpoint.
3. Asks the buyer to **paste a Google Drive folder link**, then shows the SA email so they can share **that** folder as Viewer (Notify off).
4. Polls `files.get` on the pasted folder ID until the SA token can read it. The folder name is not shown before that — the app cannot see it yet. The waiting copy is “Waiting for access to your folder”.
5. Binds that folder ID (`BoundFolderStore`) and opens the browser. The sidebar lists bound folders only (name + item count). My Drive and other people’s shares are not listed.

## What to create in GCP (`driveflow-503421`)

1. Enable **Google Drive API**.
2. Create a **service account** (IAM → Service accounts). Example email:
   `lic-xxxxx@driveflow-503421.iam.gserviceaccount.com`.
3. For local/dev only: create a JSON key and store it on the Mac under
   `~/Library/Application Support/Driveflow/service-account.json` (mode `600`)
   or point `DRIVEFLOW_SA_KEY_PATH` at it.
4. Do **not** enable domain-wide delegation for this flow.
5. Do **not** put the JSON key in the app bundle, git, or rclone config.

When a user shares a folder with the SA as Viewer (Notify unchecked), `files.get`
on that folder ID starts succeeding for the SA token. Shared Drives require adding
the SA as a **member** of the shared drive. Google Workspace tenants may block
sharing with external addresses — that’s an admin setting, not an app bug.

## Token model

| Identity | Scope / credential | Used for |
| --- | --- | --- |
| Buyer Google account | `openid email` (Desktop OAuth + PKCE) | License check (`POST {email}`), mint `Authorization`, UI “signed in as” |
| Service account | `drive.readonly` via mint API or dev 2LO JWT | Drive `files.get` / list + rclone download |

The Mac app may hold:

- The buyer’s Google **ID token** (short-lived, in the same session store as the sign-in tokens)
- Public **share email** (display / copy)
- Short-lived **SA access token** + expiry in the existing credential store

It must never ship or persist the SA private key in production builds.

### Mint resolution order

1. **Mint HTTP API.** Release builds default to `https://usedriveflow.app/api/drive/session`. Debug builds leave this unset. `DRIVEFLOW_SHARE_MINT_URL` overrides either. HTTP errors do **not** fall through to a local key.
2. **Extended license check** — same share fields on `DRIVEFLOW_LICENSE_CHECK_URL` when `allowed: true` (dev / transitional). This path is separate from `ShareMintClient.mint`.
3. **Local SA JSON** — Application Support / `DRIVEFLOW_SA_KEY_PATH` (dev). Used only when the mint URL is unset.
4. **Env token** — `DRIVEFLOW_SHARE_EMAIL` + `DRIVEFLOW_SHARE_ACCESS_TOKEN` (+ optional `DRIVEFLOW_SHARE_TOKEN_EXPIRES_IN`). Used only when the mint URL is unset.

### Mint API contract

The buyer is authenticated with the Google ID token from the Desktop OAuth token response (`id_token`, scope `openid email`). The app stores that `id_token` from both the authorization-code exchange and every refresh-token grant. The server verifies the token (signature, audience = the Driveflow OAuth client ID, expiry) and treats the token’s `email` claim as the buyer.

```http
POST https://usedriveflow.app/api/drive/session
Authorization: Bearer <google_id_token>
Content-Type: application/json

{"idToken":"<google_id_token>"}
```

`<google_id_token>` is the raw JWT string, not the SA access token. The header is what the app sends. A JSON body of `{ "idToken" }` is also accepted by the server, so the app sends both. An optional `email` field is accepted only when it matches the token; the app does not send it.

```json
{
  "shareEmail": "lic-xxxxx@driveflow-503421.iam.gserviceaccount.com",
  "accessToken": "ya29....",
  "expiresIn": 3600,
  "expiresAt": 1760000000
}
```

`expiresAt` is unix seconds and is preferred when both fields are present. `expiresIn` is seconds from now and is used only when `expiresAt` is absent. Both missing is an error.

| HTTP | Meaning |
| --- | --- |
| 401 | ID token rejected. The app signs the buyer out so they can sign in again. |
| 402 | Unpaid. The app signs out and shows the license message. |
| 429 | Retry with backoff (`Retry-After` when present, otherwise 1s, 2s, 4s, up to 3 retries). |
| 500 | Mint failure. The buyer stays signed in and can try again. |

License check may still return the same share fields alongside `allowed` (no ID token on that older call):

```json
{
  "allowed": true,
  "shareEmail": "lic-xxxxx@driveflow-503421.iam.gserviceaccount.com",
  "accessToken": "ya29....",
  "expiresIn": 3600
}
```

License email is always the **buyer** Google email — never the share-target inbox.

## Add-folder flow

1. Paste a folder link. Recognized forms include:
   - `https://drive.google.com/drive/folders/<id>`
   - `https://drive.google.com/drive/u/<n>/folders/<id>`
   - `https://drive.google.com/drive/mobile/folders/<id>`
   - `https://drive.google.com/open?id=<id>`
   - `https://drive.google.com/folderview?id=<id>`
   - `https://drive.google.com/embeddedfolderview?id=<id>`
   - a bare folder ID
   File links (`/file/d/`, Docs, Sheets, Slides) show an error instead of “Folder link recognized”.
2. Copy the share email, or choose **Open sharing in Drive**. That opens `https://drive.google.com/drive/folders/<id>` in the default browser. Hints: role Viewer, uncheck “Notify people”.
3. After either of those actions (in either order with the paste), the app polls `files.get` every few seconds with the SA token:
   `GET https://www.googleapis.com/drive/v3/files/<id>?fields=id,name,mimeType,shortcutDetails(targetId,targetMimeType)&supportsAllDrives=true`
   - `404` / `403` → keep waiting
   - folder → bind the pasted ID and enter the browser
   - shortcut to a folder → bind the **target** folder ID (children are listed on the target, not the shortcut)
   - any other readable file → stop and say it isn’t a folder
4. **Cancel** stops polling and stays on the form. It does not bind the folder.
5. The browser sidebar section **Shared with Driveflow** lists bound folders (name and item count). **+ Add folder** reopens this screen. The main pane is the existing browse / transfers UI, rooted at the selected bound folder.

## Isolation

Ideal: **one SA per license** (backend provisions SA emails). GCP projects typically
allow on the order of **~100 service accounts**, so high volume needs a provisioning
strategy or a different isolation design.

This version supports **one shared SA** plus **bound folder IDs per buyer email**
(`BoundFolderStore` under Application Support). The browser does not call
`sharedWithMe = true`. It only `files.get`s the pasted ID and lists children of
bound folders. Search is limited to those IDs and their direct children. Caveats:

- A stolen shared SA token/key can still call Drive as that SA outside the app and see every folder ever shared with it.
- Search does not walk nested descendants (only the bound folder and its direct children).

## Local test plan

1. Create/use one SA; place its JSON key in Application Support (gitignored). Do not commit it.
2. Configure Desktop OAuth client for sign-in (`openid email`).
3. Run the app → Sign in with Google.
4. On **Add a folder**, paste `https://drive.google.com/drive/folders/<id>`. The status reads **Folder link recognized**. A file link or random text shows an error. The folder name is not shown.
5. Copy the share email (**Copy** becomes **Copied**). **Open sharing in Drive** opens that folder in the default browser.
6. In Drive, share the folder as **Viewer** and uncheck **Notify people**.
7. The panel reads **Waiting for access…** / **Checking every few seconds**, and the line under the link reads **Waiting for access to your folder** (not the folder title).
8. When `files.get` succeeds, the app binds that ID and opens the browser. The sidebar lists the folder under **Shared with Driveflow** with its name and item count.
9. **+ Add folder** returns to step 4. **Cancel** on the waiting panel stays on the form and does not bind.
10. Download via rclone; confirm the transfer uses the SA token.
11. Release builds mint at `https://usedriveflow.app/api/drive/session` (`DRIVEFLOW_SHARE_MINT_URL` overrides). The call is `POST` with `Authorization: Bearer <id_token>` and body `{ "idToken": "<id_token>" }`. The response is `{ shareEmail, accessToken, expiresIn, expiresAt }` and the app prefers `expiresAt`. 401 returns to sign-in, 402 shows the unpaid state, 429 backs off, 500 shows a mint failure.

Unit tests (no network): folder-link parsing, `files.get` probe → bind / keep waiting / not a folder, and the mint request shape. Run `xcodebuild test` as in [CONTRIBUTING.md](../CONTRIBUTING.md).

Helper for env-token testing when the mint URL is unset: `./scripts/mint-sa-token.py --print-exports`.

## Out of scope

- Google Picker / `drive.file` user OAuth browse path
- Domain-wide delegation
- Plus-addressing / mailbox aliases as the share target
