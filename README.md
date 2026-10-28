# Driveflow

Google Drive downloads, at the speed of your connection.

A native SwiftUI Mac app (Apple Silicon, macOS 14+) that browses folders **shared with a Driveflow service-account email** and downloads them with a bundled [rclone](https://rclone.org) engine — without Chrome’s split-ZIP flow and without the Google Picker.

A signed build is at [usedriveflow.app](https://usedriveflow.app).

## How it works

1. **Sign in with Google** uses `openid email` only — that email is the **purchaser / license** identity. The ID token from that sign-in is what the mint server verifies.
2. **Add a folder**: paste a Google Drive folder link. Driveflow shows your **service-account share address** (e.g. `lic-….@driveflow-503421.iam.gserviceaccount.com`).
3. Share that folder as **Viewer**, and **uncheck Notify people** (SAs have no inbox). **Open sharing in Drive** jumps to the folder.
4. The app polls `files.get` on the pasted folder until the service account can read it, then opens the browser rooted at folders you added.
5. Browse and download use a **short-lived SA access token** (never a user `drive.readonly` grant, never an SA JSON key inside the app).

See [docs/SHARE_ACCESS.md](docs/SHARE_ACCESS.md) for the mint API contract, GCP setup, and isolation notes.

## Setup

You need macOS 14+, Apple Silicon, Xcode 15+, a Google Cloud **Desktop** OAuth client (identity), and a **service account** in project `driveflow-503421` (or your own project for local testing) with the Drive API enabled.

### 1. Fetch rclone

```bash
./scripts/fetch-rclone.sh
```

### 2. Google OAuth client (purchaser identity)

1. In Google Cloud, create/use an OAuth client of type **Desktop**.
2. Consent screen scopes needed in the app: `openid` and `email` only (no Drive scope on the user).
3. While the app is in Testing, add yourself as a test user.

Sign-in uses a loopback redirect (`http://127.0.0.1:<port>`), not a custom URL scheme.

Then either:

```bash
cp app/Driveflow/Resources/oauth-client.example.json \
   app/Driveflow/Resources/oauth-client.json
```

and paste your `client_id` and `client_secret`, or set `DRIVEFLOW_GOOGLE_CLIENT_ID` and `DRIVEFLOW_GOOGLE_CLIENT_SECRET`.

You can also put the same JSON at `~/Library/Application Support/Driveflow/oauth-client.json`.

### 3. Service account (Drive access)

1. Enable the **Google Drive API** on the GCP project.
2. Create a service account (IAM → Service accounts). Note its email — that is the share target.
3. Create a JSON key **for local/dev only**. Store it outside git, e.g.:

```bash
mkdir -p "$HOME/Library/Application Support/Driveflow"
cp ~/Downloads/your-sa.json \
  "$HOME/Library/Application Support/Driveflow/service-account.json"
chmod 600 "$HOME/Library/Application Support/Driveflow/service-account.json"
```

Or set `DRIVEFLOW_SA_KEY_PATH` to that file. **Never commit SA keys or ship them in the Mac app.**

Optional: mint a token for env-based testing:

```bash
pip install cryptography
eval "$(./scripts/mint-sa-token.py --print-exports)"
```

Release builds mint short-lived tokens at `https://usedriveflow.app/api/drive/session` (`DRIVEFLOW_SHARE_MINT_URL` overrides): `POST` with `Authorization: Bearer <Google ID token>` and body `{ "idToken" }`, response `{ shareEmail, accessToken, expiresIn, expiresAt }`. See [docs/SHARE_ACCESS.md](docs/SHARE_ACCESS.md).

### 4. Generate the Xcode project

`app/project.yml` is the source of truth.

```bash
brew install xcodegen
cd app
xcodegen generate
open Driveflow.xcodeproj
```

In Signing & Capabilities, set your Development Team. Then build and run.

CLI:

```bash
cd app
xcodebuild -project Driveflow.xcodeproj -scheme Driveflow \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../.derivedData \
  CODE_SIGNING_ALLOWED=NO build
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for rclone’s MIT license.

## License

GPLv3 — see [LICENSE](LICENSE).
