<p align="center">
  <img src="DevHub/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="112" height="112" alt="DevHub app icon">
</p>

<h1 align="center">DevHub</h1>

<p align="center"><strong>Resume AI coding work from the project, not from the tool.</strong></p>

<p align="center">
  A native, local-first macOS project cockpit for finding past sessions, keeping
  project memory, and reopening the right developer tool with the right context.
</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="PRIVACY.md">Privacy</a> ·
  <a href="ROADMAP.md">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/roooooly/DevHub/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/roooooly/DevHub/ci.yml?branch=main&label=CI" alt="CI status"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple" alt="macOS 14 or newer">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/data-local--first-1F7A67" alt="Local-first">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-7D1727" alt="MIT license"></a>
</p>

> **Source beta:** DevHub does not have a signed and notarized public binary yet.
> Build it from source for evaluation, and do not install binaries from unofficial
> mirrors. Public distribution remains blocked until the Apple signing and
> notarization requirements in [RELEASE.md](RELEASE.md) are satisfied.

![DevHub project overview rendered with synthetic fixture data](Tests/SnapshotTests/__Snapshots__/GallerySnapshotTests/projectsOverview.1.png)

_The screenshot uses synthetic projects and paths. DevHub includes English and
Simplified Chinese interfaces._

## The problem DevHub focuses on

When several local projects and AI coding tools are active at once, starting a tool is
easy. Recovering the **correct project, session, and working context** is the expensive
part. DevHub keeps the project as the stable unit of work:

1. Register a local project without copying its source into DevHub.
2. Refresh a lightweight index of supported local session records on demand.
3. Inspect a bounded conversation view or continue in the original tool.
4. Save a reviewed session summary into project memory for the next handoff.

DevHub is aimed at independent developers and small teams who maintain multiple local
repositories and use more than one coding tool. It is not a cloud session host or a
claim of lossless cross-tool conversation migration.

## Current capabilities

- Project overview, status, tags, Git state, detected scripts, and quick launchers
- Local session aggregation for Claude Code, Codex, ZCode, and Kimi metadata
- Bounded streaming readers for large JSONL histories
- On-demand conversation loading and original-tool resume where supported
- Reviewed session summaries and project-scoped memory
- Local Claude Code and Codex usage estimates, kept separate from fixed subscriptions
- Explicit permission checks for script plugins and MCP servers
- Native settings, light/dark appearance, English, and Simplified Chinese
- No background crawl of full session histories

### Tool compatibility

| Tool | Local session discovery | Conversation in DevHub | Continue or open | Project-memory handoff |
| --- | --- | --- | --- | --- |
| Claude Code | Yes | Bounded, on demand | Resume session | Append system-prompt file |
| Codex | Yes | Bounded, on demand | Resume session | New user prompt |
| ZCode | Yes | Supported local records | Resume session | Prompt argument |
| Kimi | Metadata only | No | Open app, not an exact session | No |
| OpenCode | Not yet | No | Launch from project | Prompt argument |
| VS Code | Not applicable | Not applicable | Open project | Clipboard-assisted when requested |

This table describes the paths implemented in the current source. Third-party storage
formats and command-line behavior can change, so every compatibility change needs
sanitized fixtures and version notes.

## Privacy boundary

DevHub is designed to keep project and session data on the Mac.

- No telemetry or analytics SDK is included.
- Session discovery is metadata-first; message bodies load only when opened.
- Source session files are treated as read-only.
- Tool credentials stay in macOS Keychain and are excluded from backups.
- Diagnostic export is user initiated, limited to DevHub logs, and redacts common
  credential patterns.
- Repository checks reject local databases, histories, private paths, signing files,
  and common credential shapes.

Read [PRIVACY.md](PRIVACY.md) for the complete boundary and [SECURITY.md](SECURITY.md)
for private vulnerability reporting.

## Build from source

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

The Xcode project is generated from `project.yml`. Update that file first when project
settings or resources change, then regenerate the project.

## Verify a checkout

```bash
./scripts/privacy-audit.sh
swift test --package-path DevHubPackage
xcodebuild \
  -project DevHub.xcodeproj \
  -scheme DevHub \
  -destination 'platform=macOS' \
  test CODE_SIGNING_ALLOWED=NO
```

For a local, ad-hoc-signed evaluation package, see [RELEASE.md](RELEASE.md). That path
is intentionally separate from public distribution.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md), the public [roadmap](ROADMAP.md), or a
scoped issue. Tests and documentation must use synthetic project names, paths,
sessions, screenshots, and credentials.

Questions and design proposals belong in
[Discussions](https://github.com/roooooly/DevHub/discussions). Reproducible bugs and
accepted work belong in Issues.

## License

DevHub is available under the [MIT License](LICENSE).
