# Driveflow

Google Drive downloads, at the speed of your connection.

A native SwiftUI Mac app (Apple Silicon, macOS 14+) that browses Google Drive and downloads files or folders without Chrome’s split-ZIP flow. Transfers use a bundled [rclone](https://rclone.org) engine for multi-threaded downloads, progress, pause/resume, and skip-existing.

A signed build is at [usedriveflow.app](https://usedriveflow.app).

## Setup

You need macOS 14+, Apple Silicon, Xcode 15+, and a Google Cloud **Desktop** OAuth client with the Drive API enabled.

### 1. Fetch rclone

```bash
./scripts/fetch-rclone.sh
```

### 2. Add a Google OAuth client

1. In Google Cloud, enable the **Drive API**.
2. OAuth consent screen → External → Testing → scope `https://www.googleapis.com/auth/drive.readonly`.
3. Create an OAuth client of type **Desktop**.
4. While the app is in Testing, add yourself as a test user.

Sign-in uses a loopback redirect (`http://127.0.0.1:<port>`), not a custom URL scheme.

Then either:

```bash
cp app/Driveflow/Resources/oauth-client.example.json \
   app/Driveflow/Resources/oauth-client.json
```

and paste your `client_id` and `client_secret` into that file, or set `DRIVEFLOW_GOOGLE_CLIENT_ID` and `DRIVEFLOW_GOOGLE_CLIENT_SECRET` in the Xcode scheme / your shell.

You can also put the same JSON at `~/Library/Application Support/Driveflow/oauth-client.json`.

### 3. Generate the Xcode project

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
