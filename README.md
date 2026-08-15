# DevHub

DevHub is a native, local-first workspace for organizing software projects, developer
tools, local AI sessions, memory notes, usage, subscriptions, and publishing accounts.
It is built with SwiftUI and SwiftData for macOS 14 or newer.

![DevHub project overview](Tests/SnapshotTests/__Snapshots__/GallerySnapshotTests/projectsOverview.1.png)

## Why DevHub

Developer work is usually scattered across folders, terminals, editors, AI tools,
session histories, notes, and recurring services. DevHub keeps the project as the
primary context, then connects the resources that belong to it.

- Project-centered workspace and status overview
- Local session index for supported developer tools
- Bounded, streaming JSONL readers for large histories
- Project memory, tool launchers, usage, subscriptions, and platform accounts
- MCP and script-plugin management with explicit permission checks
- Native settings, dark/light appearance, Simplified Chinese, and English
- On-demand refresh with no background crawl of full session histories

## Privacy model

DevHub is designed to keep project and session data on the Mac.

- It does not include telemetry or an analytics SDK.
- Session discovery reads local metadata; full message bodies are loaded only when a
  user opens a conversation.
- Tool credentials are stored in macOS Keychain and are never exported in backups.
- Diagnostic export is opt-in, limited to DevHub's subsystem, and redacts common
  credential patterns.
- Local databases, histories, logs, build outputs, signing material, and user-specific
  settings are excluded from Git.

See [PRIVACY.md](PRIVACY.md) for the complete data boundary.

## Build

Requirements:

- macOS 14 or newer
- Xcode with Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/roooooly/DevHub.git
cd DevHub
xcodegen generate
open DevHub.xcodeproj
```

The Xcode project is generated from `project.yml`. When project settings or resources
change, update `project.yml` first and regenerate the project.

## Test

```bash
./scripts/privacy-audit.sh
swift test --package-path DevHubPackage
xcodebuild \
  -project DevHub.xcodeproj \
  -scheme DevHub \
  -destination 'platform=macOS,arch=arm64' \
  test
```

## Local package

```bash
./scripts/release-local.sh
```

This creates an arm64 DMG and ZIP under `dist/`. The local package is ad-hoc signed and
is not notarized for public distribution. See [RELEASE.md](RELEASE.md) before sharing a
binary.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Use only
synthetic project names, paths, sessions, screenshots, and credentials in tests and
documentation.

## License

See [LICENSE](LICENSE).
