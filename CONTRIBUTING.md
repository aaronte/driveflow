# Contributing

## Prerequisites

- macOS 14+, Apple Silicon
- Xcode 15+
- A Google Cloud **Desktop** OAuth client (see the README)

## Setup

```bash
./scripts/fetch-rclone.sh

cp app/Driveflow/Resources/oauth-client.example.json \
   app/Driveflow/Resources/oauth-client.json
# add your Desktop client_id and client_secret

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
