<p align="center">
  <img src="DevHub/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="112" height="112" alt="CodeReentry app icon">
</p>

<h1 align="center">CodeReentry</h1>

<p align="center"><strong>Resume AI coding work from the project, not from the tool.</strong></p>

<p align="center">
  A native, local-first macOS project cockpit for finding past sessions, keeping
  project memory, and reopening the right developer tool with the right context.
</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="https://github.com/roooooly/CodeReentry/releases">Source beta</a> ·
  <a href="#run-from-source">Run from source</a> ·
  <a href="PRIVACY.md">Privacy</a> ·
  <a href="ROADMAP.md">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/roooooly/CodeReentry/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/roooooly/CodeReentry/ci.yml?branch=main&label=CI" alt="CI status"></a>
  <a href="https://github.com/roooooly/CodeReentry/releases"><img src="https://img.shields.io/github/v/release/roooooly/CodeReentry?include_prereleases&label=source%20beta" alt="Latest source beta"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple" alt="macOS 14 or newer">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/data-local--first-1F7A67" alt="Local-first">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-7D1727" alt="MIT license"></a>
</p>

> **Source beta:** The current source release is v0.3.2. CodeReentry does not have a signed
> and notarized public binary yet.
> Build it from source for evaluation, and do not install binaries from unofficial
> mirrors. Public distribution remains blocked until the Apple signing and
> notarization requirements in [RELEASE.md](RELEASE.md) are satisfied.

![CodeReentry project overview rendered with synthetic fixture data](Tests/SnapshotTests/__Snapshots__/GallerySnapshotTests/projectsOverview.1.png)

_The screenshot uses synthetic projects and paths. CodeReentry includes English and
Simplified Chinese interfaces._

## The problem CodeReentry focuses on

When several local projects and AI coding tools are active at once, starting a tool is
easy. Recovering the **correct project, session, and working context** is the expensive
part. CodeReentry keeps the project as the stable unit of work:

1. Register a local project without copying its source into CodeReentry.
2. Refresh a lightweight index of supported local session records on demand.
3. Inspect a bounded conversation view or continue in the original tool.
4. Save a deliberate session summary into project memory for the next handoff. CodeReentry
   records its source and warns before sending it if a newer session exists.

CodeReentry is aimed at independent developers and small teams who maintain multiple local
repositories and use more than one coding tool. It is not a cloud session host or a
claim of lossless cross-tool conversation migration.

The recovery hypothesis is tracked with a
[privacy-safe real-use protocol](docs/reentry-validation.md). Engineering tests do not
count as user evidence, and the project does not claim the workflow gate has passed yet.
Release performance is tracked separately with a
[reproducible synthetic baseline](docs/performance-baseline.md), including failed gates.

## Current capabilities

- Project overview, status, tags, Git state, detected scripts, and quick launchers
- Session-first onboarding that proposes project roots from local cwd metadata before registration
- Local session aggregation for Claude Code, Codex, ZCode, and Kimi metadata
- Bounded streaming readers for large JSONL histories
- On-demand conversation loading and original-tool resume where supported
- Guarded one-click resume that selects the latest usable session, falls back from a moved
  session subdirectory to the registered project root, and honors the saved tool command
- Project-scoped stable context plus session summaries with provenance and stale-summary protection
- Local Claude Code and Codex usage estimates, kept separate from fixed subscriptions
- Explicit permission checks for script plugins and MCP servers
- Native settings, light/dark appearance, English, and Simplified Chinese
- No background crawl of full session histories

### Tool compatibility

| Tool | Local session discovery | Conversation in CodeReentry | Continue or open | Project-memory handoff |
| --- | --- | --- | --- | --- |
| Claude Code | Yes | Bounded, on demand | Resume session | Append system-prompt file |
| Codex | Yes | Bounded, on demand | Resume session | New user prompt |
| ZCode | Yes | Supported local records | Resume session | Prompt argument |
| Kimi | Metadata only | No | Open app, not an exact session | No |
| OpenCode | Metadata (v1.18.19 SQLite) | No | Exact-session resume (`--session`) | Prompt argument |
| VS Code | Not applicable | Not applicable | Open project | Clipboard-assisted when requested |

This table describes the paths implemented in the current source. Third-party storage
formats and command-line behavior can change, so every compatibility change needs
sanitized fixtures and version notes.

OpenCode compatibility is verified against v1.18.19. CodeReentry discovers session metadata
from the default `~/.local/share/opencode/opencode.db`, an `OPENCODE_DB` override, and
bounded `opencode-<channel>.db` siblings. It validates the `session` table before use,
opens each database read-only, indexes at most 1,000 recent active sessions per database,
and does not read message bodies.

## Privacy boundary

CodeReentry is designed to keep project and session data on the Mac.

- No telemetry or analytics SDK is included.
- Session discovery is metadata-first; message bodies load only when opened.
- Source session files are treated as read-only.
- Tool credentials stay in macOS Keychain and are excluded from backups.
- Diagnostic export is user initiated, limited to CodeReentry logs, and redacts common
  credential patterns.
- Repository checks reject local databases, histories, private paths, signing files,
  and common credential shapes.

Read [PRIVACY.md](PRIVACY.md) for the complete boundary and [SECURITY.md](SECURITY.md)
for private vulnerability reporting.

## Run from source

Requirements:

- macOS 14 or newer
- Xcode with Swift 6 support

Clone, build, verify, and launch a local ad-hoc-signed copy with one command:

```bash
git clone https://github.com/roooooly/CodeReentry.git
cd CodeReentry
./scripts/run-source.sh
```

The script uses the committed Xcode project, writes build products only under the
ignored `build/` directory, verifies the resulting bundle, and does not scan projects
or sessions before you explicitly request it in the app. Pass `--build-only` to build
without launching. The first build can take several minutes while Swift packages are
resolved and compiled.

On first launch, choose **Find projects from sessions** for the shortest path to value.
CodeReentry performs one explicit metadata-only scan, proposes at most 20 recent project
roots, and waits for confirmation before registering anything. **Choose folders manually**
keeps the directory-based setup available.

To develop in Xcode, install [XcodeGen](https://github.com/yonaskolb/XcodeGen), run
`xcodegen generate`, and open `DevHub.xcodeproj`. The project is generated from
`project.yml`; update that file first when project settings or resources change.

## Verify a checkout

```bash
./scripts/privacy-audit.sh
./scripts/test-performance-summary.sh
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
[Discussions](https://github.com/roooooly/CodeReentry/discussions). Reproducible bugs and
accepted work belong in Issues.

## License

CodeReentry is available under the [MIT License](LICENSE).
