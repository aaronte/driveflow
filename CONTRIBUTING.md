# Contributing

## Prerequisites

- macOS 14+, Apple Silicon
- Xcode 15+
- A Google Cloud **Desktop** OAuth client (identity: `openid email`)
- A Google Cloud **service account** for Drive share-access (see [docs/SHARE_ACCESS.md](docs/SHARE_ACCESS.md))

## Setup

```bash
./scripts/fetch-rclone.sh

cp app/Driveflow/Resources/oauth-client.example.json \
   app/Driveflow/Resources/oauth-client.json
# add your Desktop client_id and client_secret

# Local/dev Drive access — never commit this file
mkdir -p "$HOME/Library/Application Support/Driveflow"
cp /path/to/your-sa-key.json \
  "$HOME/Library/Application Support/Driveflow/service-account.json"
chmod 600 "$HOME/Library/Application Support/Driveflow/service-account.json"

brew install xcodegen
cd app && xcodegen generate && cd ..
open app/Driveflow.xcodeproj
```

Set your Development Team under Signing & Capabilities, then run.

`app/project.yml` is the project source of truth — edit it, then run `xcodegen generate`.

```bash
cd app
xcodebuild -project Driveflow.xcodeproj -scheme Driveflow \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../.derivedData build
xcodebuild -project Driveflow.xcodeproj -scheme Driveflow \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../.derivedData test
```

## Commits

Follow [.github/COMMIT_CONVENTION.md](.github/COMMIT_CONVENTION.md).

## License

By contributing, you agree your contributions are licensed under GPLv3
(see [LICENSE](LICENSE)). rclone remains MIT — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
